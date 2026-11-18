#!/usr/bin/env python3
"""Forwarding (forward.goose): the loop moves a connection's bytes to a fixed target and back by itself. Bytes arrive whole and in
order both ways, a large transfer survives, an end of stream on either side reaches the other, concurrent connections do not mix,
and a dead target ends the client's connection."""
import hashlib, os, socket, threading
from netlib import *

# the target: an echo service, one thread per connection, that also reports what it saw end
target = socket.socket(); target.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
target.bind(("127.0.0.1", 0)); target.listen(64)
tport = target.getsockname()[1]
ended = []

def serve(conn):
    try:
        while True:
            d = conn.recv(65536)
            if not d: ended.append("eof"); break
            conn.sendall(d)
    except OSError: ended.append("error")
    finally: conn.close()

def accept_loop():
    while True:
        try: c, _ = target.accept()
        except OSError: return
        threading.Thread(target=serve, args=(c,), daemon=True).start()
threading.Thread(target=accept_loop, daemon=True).start()

port = free_port()
p = start("forward_server", "--listen", f"127.0.0.1:{port}", "--to", f"127.0.0.1:{tport}")
check(wait_listening(port), "the forwarder listens")

def read_n(c, n, seconds=10):
    c.settimeout(seconds); buf = b""
    while len(buf) < n:
        d = c.recv(n - len(buf))
        if not d: break
        buf += d
    return buf

# bytes go to the target and come back, in order
c = socket.create_connection(("127.0.0.1", port), 3)
c.sendall(b"hello\n"); check(read_n(c, 6) == b"hello\n", "a short message is echoed through the forwarder")
c.sendall(b"a"); c.sendall(b"b"); c.sendall(b"c"); check(read_n(c, 3) == b"abc", "small writes arrive in order")

# a large transfer, sent while it is read back, arrives whole and unchanged
blob = os.urandom(8 * 1024 * 1024)
got = []
t = threading.Thread(target=lambda: got.append(read_n(c, len(blob), 30)))
t.start(); c.sendall(blob); t.join()
check(len(got[0]) == len(blob) and hashlib.sha256(got[0]).digest() == hashlib.sha256(blob).digest(), "8 MiB goes through unchanged both ways")

# the client's end of stream reaches the target, and the target's reaches the client
ended.clear()
c.shutdown(socket.SHUT_WR)
c.settimeout(5)
check(c.recv(10) == b"", "the target's end of stream (after the client's) reaches the client")
check("eof" in ended, "the client's end of stream reaches the target")
c.close()

# concurrent connections do not mix their bytes
results = []
def one(i):
    s = socket.create_connection(("127.0.0.1", port), 3)
    data = (f"conn{i}-".encode() * 4000)
    s.sendall(data); results.append(read_n(s, len(data)) == data); s.close()
ts = [threading.Thread(target=one, args=(i,)) for i in range(40)]
[x.start() for x in ts]; [x.join() for x in ts]
check(len(results) == 40 and all(results), "40 concurrent connections each get exactly their own bytes back")

# a client that closes while the target still has data to send does not take the forwarder down
for _ in range(20):
    s = socket.create_connection(("127.0.0.1", port), 3); s.sendall(b"x" * 100000); s.close()
s = socket.create_connection(("127.0.0.1", port), 3); s.sendall(b"ping"); check(read_n(s, 4) == b"ping", "the forwarder works after abrupt client closes"); s.close()

# the target goes away: the client's connection ends, the forwarder survives
target.close()
dead = socket.create_connection(("127.0.0.1", port), 3); dead.settimeout(5)
try: end = dead.recv(10)
except OSError: end = b""
check(end == b"", "a client of a dead target is closed")
dead.close()
check(wait_listening(port), "the forwarder still listens after the target is gone")

code, out = stop(p)
check(code == 0, f"the forwarder drains and exits 0 on SIGTERM (exit {code})")
finish()
