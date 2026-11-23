#!/usr/bin/env python3
"""The system-call gate: the same requests against a baseline and a candidate server under `strace -c -f`, and the system calls
per request compared. Exit status 0 only if recvfrom, sendto, epoll_wait, epoll_ctl, accept4 and close per request are equal.

  python3 bench/gate_syscalls.py BASELINE CANDIDATE [--requests N] [--connections M] [--tolerance T]

Two workloads, each a client that sends requests one at a time (so the work per request is deterministic):
  keep-alive   N requests on one connection              (recvfrom, sendto, epoll_wait per request)
  new-conn     M connections of one request each         (accept4, epoll_ctl, close per connection)
Both servers are started as `PROGRAM PORT` and stopped with SIGINT, as tcprouter's bench/syscalls.py does. A call is equal when the
two counts are equal, or differ by at most 40 (the calls of start-up and shutdown), or by at most the tolerance as a fraction of the
rate (default 0.002). epoll_wait, which also counts idle wakeups and how many events one wakeup finds, is held to "the candidate makes no more" within 3%. Every per-request and per-connection call of the
handler path is exactly deterministic, so a call made once more for each request or connection is far outside both.
"""
import argparse, os, re, signal, socket, subprocess, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tests", "net"))
from netlib import free_port, wait_listening

REQ = b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"
CALLS = ["recvfrom", "sendto", "epoll_wait", "epoll_ctl", "accept4", "close"]


def run(program, work):
    port = free_port()
    out = f"/tmp/gate-strace-{os.getpid()}-{os.path.basename(program)}.txt"
    p = subprocess.Popen(["strace", "-c", "-f", "-o", out, program, str(port)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not wait_listening(port, 10):
        raise SystemExit(f"{program} did not listen")
    time.sleep(0.3)
    work(port)
    time.sleep(0.3)
    for q in subprocess.run(["pgrep", "-f", f"{program} {port}"], capture_output=True, text=True).stdout.split():
        if int(q) != p.pid:
            try: os.kill(int(q), signal.SIGINT)
            except OSError: pass
    p.wait(timeout=30)
    return parse(open(out).read())




def parse(text):
    counts = {}
    for line in text.splitlines():
        m = re.match(r"\s*[\d.]+\s+[\d.]+\s+\d+\s+(\d+)\s+(?:\d+\s+)?(\w+)\s*$", line)
        if m: counts[m.group(2)] = int(m.group(1))
    return counts


def keep_alive(n):
    def work(port):
        s = socket.create_connection(("127.0.0.1", port))
        for _ in range(n):
            s.sendall(REQ)
            buf = b""
            while not buf.endswith(b"hello\n"):
                buf += s.recv(4096)
        s.close()
    return work


def new_conn(m):
    def work(port):
        for _ in range(m):
            s = socket.create_connection(("127.0.0.1", port))
            s.sendall(REQ)
            buf = b""
            while not buf.endswith(b"hello\n"):
                buf += s.recv(4096)
            s.close()
    return work


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("baseline"); ap.add_argument("candidate")
    ap.add_argument("--requests", type=int, default=20000)
    ap.add_argument("--connections", type=int, default=2000)
    ap.add_argument("--tolerance", type=float, default=0.002)
    a = ap.parse_args()
    ok = True
    print(f"{'workload':12} {'call':10} {'baseline':>10} {'candidate':>10}   per request: baseline / candidate")
    for name, work, n in (("keep-alive", keep_alive(a.requests), a.requests), ("new-conn", new_conn(a.connections), a.connections)):
        b = run(a.baseline, work); c = run(a.candidate, work)
        for call in CALLS:
            bb, cc = b.get(call, 0), c.get(call, 0)
            rb, rc = bb / n, cc / n
            # a call made a few times for the whole run (listener set-up, the one connection) is not a rate: only a difference
            # of more than `slack` per request counts; epoll_wait also counts idle wakeups, which depend on how long the run took
            tol = 0.03 if call == "epoll_wait" else a.tolerance
            # and the set-up and shutdown of a process make a few dozen calls of any kind (the constant below)
            same = (bb == cc) or abs(bb - cc) <= 40 or abs(rb - rc) / max(rb, rc) <= tol
            if call == "epoll_wait":                 # how many events one wakeup finds depends on timing: fewer wakeups is not a worse loop
                same = cc <= bb * (1 + tol) + 40
            if not same: ok = False
            print(f"{name:12} {call:10} {bb:10d} {cc:10d}   {rb:7.3f} / {rc:7.3f}  {'equal' if same else 'DIFFERENT'}")
    print("gate:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


main()
