#!/usr/bin/env python3
"""The throughput gate: a baseline and a candidate HTTP server measured with wrk in alternating rounds, one worker, pinned CPUs.
Exit status 0 only if, at each connection count, the candidate's median throughput and p99 latency and CPU per request fall within
or beat the baseline's own min-to-max range.

  python3 bench/gate_http.py BASELINE CANDIDATE [--rounds 7] [--seconds 6] [--connections 64,512] [--server-cpu 2] [--wrk-cpus 4,5]

Each server is started as `PROGRAM PORT 1` (one worker) on its CPU; wrk runs on its own CPUs. A round is void, and is repeated,
when the server was not the limit: its CPU use over the round was below 90% of one core, so wrk or the host was.
CPU per request is the server's user+system time (/proc/PID/stat) over the round divided by the requests wrk completed.
"""
import argparse, os, re, signal, statistics, subprocess, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "net"))
from netlib import free_port, wait_listening

CLK = os.sysconf("SC_CLK_TCK")


def cpu_ticks(pid):
    with open(f"/proc/{pid}/stat") as f:
        parts = f.read().rsplit(")", 1)[1].split()
    return int(parts[11]) + int(parts[12])           # utime + stime


def latency_us(text):
    m = re.search(r"99%\s+([\d.]+)(us|ms|s)", text)
    v = float(m.group(1)); u = m.group(2)
    return v * {"us": 1, "ms": 1000, "s": 1000000}[u]


def one_round(program, conns, seconds, server_cpu, wrk_cpus):
    port = free_port()
    srv = subprocess.Popen(["taskset", "-c", str(server_cpu), program, str(port), "1"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        if not wait_listening(port, 10):
            raise SystemExit(f"{program} did not listen")
        # warm up, then measure
        subprocess.run(["taskset", "-c", wrk_cpus, "wrk", "-t2", f"-c{conns}", "-d1s", f"http://127.0.0.1:{port}/"], capture_output=True)
        t0 = cpu_ticks(srv.pid); w0 = time.time()
        r = subprocess.run(["taskset", "-c", wrk_cpus, "wrk", "-t2", f"-c{conns}", f"-d{seconds}s", "--latency", f"http://127.0.0.1:{port}/"], capture_output=True, text=True)
        t1 = cpu_ticks(srv.pid); w1 = time.time()
    finally:
        srv.send_signal(signal.SIGINT); 
        try: srv.wait(timeout=20)
        except subprocess.TimeoutExpired: srv.kill()
    reqs = int(re.search(r"(\d+) requests in", r.stdout).group(1))
    rps = float(re.search(r"Requests/sec:\s+([\d.]+)", r.stdout).group(1))
    cpu = (t1 - t0) / CLK
    util = cpu / (w1 - w0)
    return {"rps": rps, "p99": latency_us(r.stdout), "cpu_us_per_req": cpu / reqs * 1e6, "util": util}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("baseline"); ap.add_argument("candidate")
    ap.add_argument("--rounds", type=int, default=7); ap.add_argument("--seconds", type=int, default=6)
    ap.add_argument("--connections", default="64,512")
    ap.add_argument("--server-cpu", default="2"); ap.add_argument("--wrk-cpus", default="4,5")
    a = ap.parse_args()
    ok = True
    for conns in map(int, a.connections.split(",")):
        res = {"baseline": [], "candidate": []}
        voided = 0
        while len(res["baseline"]) < a.rounds and voided < 3 * a.rounds:
            for name, prog in (("baseline", a.baseline), ("candidate", a.candidate)):
                r = one_round(prog, conns, a.seconds, a.server_cpu, a.wrk_cpus)
                if r["util"] < 0.9:
                    voided += 1; print(f"  void ({name}, {conns} conns): server used {r['util']:.0%} of its core", flush=True); continue
                res[name].append(r)
            n = min(len(res["baseline"]), len(res["candidate"]))
            res["baseline"] = res["baseline"][:n]; res["candidate"] = res["candidate"][:n]
        print(f"\n{conns} connections, {len(res['baseline'])} alternating rounds (voided {voided})")
        print(f"  {'metric':16} {'baseline min':>13} {'median':>11} {'max':>11}   {'candidate median':>17}  verdict")
        for key, label, better in (("rps", "requests/s", "high"), ("p99", "p99 latency us", "low"), ("cpu_us_per_req", "cpu us/request", "low")):
            b = [r[key] for r in res["baseline"]]; c = [r[key] for r in res["candidate"]]
            if not b: ok = False; print("  no valid rounds"); continue
            cm = statistics.median(c)
            within = (min(b) <= cm <= max(b)) or (cm >= max(b) if better == "high" else cm <= min(b))
            if not within: ok = False
            print(f"  {label:16} {min(b):13.1f} {statistics.median(b):11.1f} {max(b):11.1f}   {cm:17.1f}  {'ok' if within else 'WORSE'}")
    print("\ngate:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


main()
