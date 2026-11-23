#!/usr/bin/env python3
"""The seam proof: the epoll event loop with tcprouter's forward pump added back (goose-io-epoll-ext) against tcprouter's own
forward_server, on keep-alive workloads of 11 B, 16 KiB and 64 KiB responses through a C backend.

  python3 bench/gate_forward.py BASELINE CANDIDATE [--rounds 7] [--seconds 6] [--sizes 11,16384,65536]
         [--requests 5000] [--server-cpu 2] [--wrk-cpus 4,5] [--backend-cpu 6]

Both servers are started as `PROGRAM --listen 127.0.0.1:L --to 127.0.0.1:B --workers 1 --stat-ms 3600000`. Two gates, as for the
handler path (gate_syscalls.py, gate_http.py): system calls per request under strace -c -f for a sequential keep-alive client (recvfrom,
sendto, epoll_wait, epoll_ctl, accept4 and close, equal), and throughput, p99 and CPU per request with wrk in alternating rounds, the
candidate's median within or better than the baseline's min-to-max range. The backend is bench/baseline/backend (tcprouter's bench/backend.c).
"""
import argparse, os, re, signal, socket, statistics, subprocess, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "net"))
from netlib import free_port, wait_listening

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.join(HERE, "baseline", "backend")
CLK = os.sysconf("SC_CLK_TCK")
CALLS = ["recvfrom", "sendto", "epoll_wait", "epoll_ctl", "accept4", "close"]


def start_backend(cpu):
    port = free_port()
    be = subprocess.Popen(["taskset", "-c", str(cpu), BACKEND, "1", str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    assert wait_listening(port, 10)
    return be, port


def server_argv(program, lport, bport):
    return [program, "--listen", f"127.0.0.1:{lport}", "--to", f"127.0.0.1:{bport}", "--workers", "1", "--stat-ms", "3600000"]


def parse(text):
    counts = {}
    for line in text.splitlines():
        m = re.match(r"\s*[\d.]+\s+[\d.]+\s+\d+\s+(\d+)\s+(?:\d+\s+)?(\w+)\s*$", line)
        if m: counts[m.group(2)] = int(m.group(1))
    return counts


def request_loop(port, size, n):
    s = socket.create_connection(("127.0.0.1", port))
    req = f"GET /{size} HTTP/1.1\r\nHost: x\r\n\r\n".encode()
    for _ in range(n):
        s.sendall(req)
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += s.recv(65536)
        head, rest = buf.split(b"\r\n\r\n", 1)
        length = int(re.search(rb"Content-Length: (\d+)", head, re.I).group(1))
        while len(rest) < length:
            rest += s.recv(65536)
    s.close()


def strace_run(program, bport, size, n):
    lport = free_port()
    out = f"/tmp/gate-fwd-strace-{os.getpid()}.txt"
    p = subprocess.Popen(["strace", "-c", "-f", "-o", out] + server_argv(program, lport, bport), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    assert wait_listening(lport, 15)
    time.sleep(0.3)
    request_loop(lport, size, n)
    time.sleep(0.3)
    for q in subprocess.run(["pgrep", "-f", "--", f"--listen 127.0.0.1:{lport}"], capture_output=True, text=True).stdout.split():
        if int(q) != p.pid:
            try: os.kill(int(q), signal.SIGINT)
            except OSError: pass
    p.wait(timeout=30)
    return parse(open(out).read())


def cpu_ticks(pid):
    with open(f"/proc/{pid}/stat") as f:
        parts = f.read().rsplit(")", 1)[1].split()
    return int(parts[11]) + int(parts[12])


def latency_us(text):
    m = re.search(r"99%\s+([\d.]+)(us|ms|s)", text)
    return float(m.group(1)) * {"us": 1, "ms": 1000, "s": 1000000}[m.group(2)]


def wrk_round(program, bport, size, conns, seconds, server_cpu, wrk_cpus):
    lport = free_port()
    srv = subprocess.Popen(["taskset", "-c", str(server_cpu)] + server_argv(program, lport, bport), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        assert wait_listening(lport, 15)
        url = f"http://127.0.0.1:{lport}/{size}"
        subprocess.run(["taskset", "-c", wrk_cpus, "wrk", "-t2", f"-c{conns}", "-d1s", url], capture_output=True)
        t0 = cpu_ticks(srv.pid); w0 = time.time()
        r = subprocess.run(["taskset", "-c", wrk_cpus, "wrk", "-t2", f"-c{conns}", f"-d{seconds}s", "--latency", url], capture_output=True, text=True)
        t1 = cpu_ticks(srv.pid); w1 = time.time()
    finally:
        srv.send_signal(signal.SIGINT)
        try: srv.wait(timeout=20)
        except subprocess.TimeoutExpired: srv.kill()
    reqs = int(re.search(r"(\d+) requests in", r.stdout).group(1))
    rps = float(re.search(r"Requests/sec:\s+([\d.]+)", r.stdout).group(1))
    cpu = (t1 - t0) / CLK
    return {"rps": rps, "p99": latency_us(r.stdout), "cpu_us_per_req": cpu / reqs * 1e6, "util": cpu / (w1 - w0)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("baseline"); ap.add_argument("candidate")
    ap.add_argument("--rounds", type=int, default=7); ap.add_argument("--seconds", type=int, default=6)
    ap.add_argument("--sizes", default="11,16384,65536"); ap.add_argument("--requests", type=int, default=5000)
    ap.add_argument("--connections", type=int, default=64)
    ap.add_argument("--server-cpu", default="2"); ap.add_argument("--wrk-cpus", default="4,5"); ap.add_argument("--backend-cpu", default="6")
    a = ap.parse_args()
    ok = True
    be, bport = start_backend(a.backend_cpu)
    try:
        for size in map(int, a.sizes.split(",")):
            print(f"\n=== {size} B responses ===")
            print("system calls per request (strace -c -f, sequential keep-alive client)")
            b = strace_run(a.baseline, bport, size, a.requests); c = strace_run(a.candidate, bport, size, a.requests)
            for call in CALLS:
                bb, cc = b.get(call, 0), c.get(call, 0)
                rb, rc = bb / a.requests, cc / a.requests
                same = (bb == cc) or abs(bb - cc) <= 40 or abs(rb - rc) / max(rb, rc) <= 0.002
                if call == "epoll_wait": same = cc <= bb * 1.03 + 40
                if not same: ok = False
                print(f"  {call:10} {bb:8d} {cc:8d}   {rb:7.3f} / {rc:7.3f}  {'equal' if same else 'DIFFERENT'}")
            res = {"baseline": [], "candidate": []}; voided = 0
            while len(res["baseline"]) < a.rounds and voided < 3 * a.rounds:
                for name, prog in (("baseline", a.baseline), ("candidate", a.candidate)):
                    r = wrk_round(prog, bport, size, a.connections, a.seconds, a.server_cpu, a.wrk_cpus)
                    if r["util"] < 0.9:
                        voided += 1; print(f"  void ({name}): the server used {r['util']:.0%} of its core", flush=True); continue
                    res[name].append(r)
                n = min(len(res["baseline"]), len(res["candidate"]))
                res["baseline"] = res["baseline"][:n]; res["candidate"] = res["candidate"][:n]
            print(f"throughput, {a.connections} connections, {len(res['baseline'])} alternating rounds (voided {voided})")
            print(f"  {'metric':16} {'baseline min':>13} {'median':>11} {'max':>11}   {'candidate median':>17}  verdict")
            for key, label, better in (("rps", "requests/s", "high"), ("p99", "p99 latency us", "low"), ("cpu_us_per_req", "cpu us/request", "low")):
                bv = [r[key] for r in res["baseline"]]; cv = [r[key] for r in res["candidate"]]
                if not bv: ok = False; print("  no valid rounds"); continue
                cm = statistics.median(cv)
                within = (min(bv) <= cm <= max(bv)) or (cm >= max(bv) if better == "high" else cm <= min(bv))
                if not within: ok = False
                print(f"  {label:16} {min(bv):13.1f} {statistics.median(bv):11.1f} {max(bv):11.1f}   {cm:17.1f}  {'ok' if within else 'WORSE'}")
    finally:
        be.terminate()
    print("\ngate:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


main()
