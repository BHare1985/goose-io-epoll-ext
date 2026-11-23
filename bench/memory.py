#!/usr/bin/env python3
"""Resident memory of the baseline and the candidate HTTP server, measured the same way for both.

  python3 bench/memory.py BASELINE CANDIDATE [--idle-links 10000]

Reads VmRSS from /proc/PID/status of each server (started as `PROGRAM PORT 1`, one worker): idle, with N idle connections held open,
and after a short wrk load (VmHWM). Per idle link is (RSS with N idle - RSS idle) / N. Exit status 0 only if the candidate's RSS
is no more than the baseline's (within 3%) in each of the three, and a link that holds no state of the program's own costs at most 512 bytes (--idle-baseline and --idle-candidate name the programs that measure it).
"""
import argparse, os, resource, signal, socket, subprocess, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "net"))
from netlib import free_port, rss_kb, wait_listening


def hwm_kb(pid):
    for line in open(f"/proc/{pid}/status"):
        if line.startswith("VmHWM:"):
            return int(line.split()[1])
    return 0


def measure(program, n):
    port = free_port()
    p = subprocess.Popen([program, str(port), "1"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        assert wait_listening(port, 10)
        time.sleep(1.0)
        idle = rss_kb(p.pid)
        conns = [socket.create_connection(("127.0.0.1", port), timeout=10) for _ in range(n)]
        time.sleep(1.5)
        held = rss_kb(p.pid)
        for c in conns: c.close()
        time.sleep(1.0)
        subprocess.run(["wrk", "-t2", "-c256", "-d4s", f"http://127.0.0.1:{port}/"], capture_output=True)
        return {"idle_kb": idle, "held_kb": held, "per_link_bytes": (held - idle) * 1024 / n, "load_hwm_kb": hwm_kb(p.pid)}
    finally:
        p.send_signal(signal.SIGINT)
        try: p.wait(timeout=20)
        except subprocess.TimeoutExpired: p.kill()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("baseline"); ap.add_argument("candidate"); ap.add_argument("--idle-links", type=int, default=10000)
    ap.add_argument("--idle-baseline"); ap.add_argument("--idle-candidate")
    a = ap.parse_args()
    resource.setrlimit(resource.RLIMIT_NOFILE, (a.idle_links * 2 + 1000,) * 2)
    b = measure(a.baseline, a.idle_links); c = measure(a.candidate, a.idle_links)
    # what a link costs the loop itself is measured with programs that keep no state of their own for a link
    bi = measure(a.idle_baseline, a.idle_links) if a.idle_baseline else b
    ci = measure(a.idle_candidate, a.idle_links) if a.idle_candidate else c
    print(f"{'':28} {'baseline':>12} {'candidate':>12}")
    for k, label in (("idle_kb", "idle RSS (kB)"), ("held_kb", f"RSS, {a.idle_links} idle links (kB)"), ("per_link_bytes", "bytes per idle link"), ("load_hwm_kb", "peak RSS under load (kB)")):
        print(f"{label:28} {b[k]:12.1f} {c[k]:12.1f}")
    if a.idle_baseline:
        print(f"{'bytes per idle link, no state':28} {bi['per_link_bytes']:12.1f} {ci['per_link_bytes']:12.1f}   (programs of their own, answering nothing)")
    ok = ci["per_link_bytes"] <= 512 and c["idle_kb"] <= b["idle_kb"] * 1.03 and c["held_kb"] <= b["held_kb"] * 1.03 and c["load_hwm_kb"] <= b["load_hwm_kb"] * 1.03
    print("gate:", "PASS" if ok else "FAIL", "(no more than the baseline, within 3%; at most 512 bytes per idle link)")
    sys.exit(0 if ok else 1)


main()
