## Why

goose-io has a contract (0.2), a conformance suite and one working event loop, the in-memory one, which opens no socket. No library has run on a real network through it. tcprouter's epoll engine is the loop the contract was drawn from, benchmarked and in use by skein, so it is the fastest way to a loop on real sockets and to proof that the contract costs nothing.

## What Changes

- Add a Linux epoll event loop under `examples/loops/epoll/`, outside the pure-Goose package (it needs a C layer for sockets and epoll), made from tcprouter's engine: the worker loop, slots and generations, buffer pool, send queue, dial, timeouts, drain and statistics. It supplies the core and the five groups it is written for (half-close, sizing, abort, inspection and batching), and passes the core and each of those groups of the conformance suite; whether it also supplies the unix group is decided when it is applied.
- Import tcprouter's engine and its tests unmodified first, then separate the generic engine from the proxy code and move it to the contract's names in small steps, each with the imported tests green. This follows the order of the abandoned change `define-io-contract`, which never started.
- Add the operations tcprouter lacks: runtime `listen`, `listener_port`, `stop_listening`, `peer_address`, `send2` and `tick_by`; add the behaviour changes the mapping document (`docs/event-loops/tcprouter-engine.md`) lists (`Writable` once the largest refused send fits, `close` that does not reset a link with unread input, a slot kept until the handlers of its `Closed` have returned, a dial that failed inside `dial` included), and keep slots dense with a free list, as contract 0.2 requires. Nothing is attached to a link: no tag and no user value (the proxy layer's own route tags are the extension's state).
- Add an extension seam (compile-time hooks, empty by default) so tcprouter's routing, SNI inspection and forwarding can later be plugged into the same loop.
- Add performance gates against tcprouter's own engine on the same workloads, and a seam proof: a forwarding extension must hold tcprouter's forwarding numbers.
- Run the example libraries on real sockets, the line client and the line server, with the same tests that run on the in-memory loop.

Out of scope: refactoring tcprouter onto goose-io (a separate project, gated by the numbers here), an io_uring loop (the next change, from c_proxy), name resolution, TLS, and non-Linux loops. Nothing in `~/dev/cnamecloud/tcprouter` is modified. The contract changes only if the conformance suite shows a requirement the loop cannot meet and every other way has been tried (docs/event-loops.md).

## Capabilities

### New Capabilities

- `epoll-event-loop`: the reference Linux epoll event loop: the contract and its conformance suite on real sockets, workers that share nothing, limits and timeouts, buffers, drain and statistics, the extension seam, and parity with tcprouter's engine.

### Modified Capabilities

None. The requirements of `io-contract` and `provider-conformance` are unchanged; this loop is held to them.

## Impact

- **goose-io code:** new `examples/loops/epoll/` (Goose and one C file), `bench/` for the gates, `tests/net/` for tests that need a real network; `docs/event-loops.md` and the README table of conforming loops gain the loop. The pure-Goose package, the suite and the contract are untouched, and `tests/checks/purity.sh` keeps excluding only `examples/loops/`.
- **tcprouter:** read-only source (`engine.goose`, `conn.goose`, `handler.goose`, `messages.goose`, `address.goose`, `sys.goose`, `src/c_sys.c`, its tests and bench). Its code has not changed since `05995d1` apart from documents.
- **Visibility:** tcprouter's repository is private and goose-io is public; moving engine code across was requested by the owner of both, and the proxy code (routes, SNI, policy) is not copied except the forward pump in the seam proof, which is reviewed by the owner before any push.
- **Toolchain:** Goose v2026.4, Linux, Python 3 for the network drivers, `strace` and `wrk` for the gates.
