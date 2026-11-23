## Context

See `proposal.md` for the motivation. The facts that shape the approach:

- **The contract and its tests exist.** Contract 0.2 is a core of twelve operations and 5 events and six groups (half-close, sizing, abort, inspection, batching and unix); nothing is attached to a link, so an event carries the link (and, for `Opened`, the listener) and a library finds its state from it; slots are dense and a slot is freed only after the handlers of its `Closed` have returned; the conformance suite runs by group (`conformance_core_part` and one entry point for each group), a loop that supplies only the core passes the core on it (`tests/support/core_only.goose`), and the example libraries run on the in-memory loop and over a wrapper. This change builds none of that again. It adds a loop that the same programs run on.
- **The mapping is done.** `docs/event-loops/tcprouter-engine.md` has one row per operation and event, marked checked or unverified against source, with the adapter work. This design turns its rows into tasks.
- **tcprouter's engine** (`05995d1`; `main` is `ea41fed`, which changes documents only) has three layers in one `Worker`: the generic layer (loop, slots and generations, buffer pool, handler path, control messages, drain, statistics, address parsing, the C socket layer, about 2,300 lines), the forwarding layer (`_pump`, readiness flags, ready queue, 64 KiB budget) and proxy policy (routes, SNI, retry, tags, deadlines, fences). skein already runs on the generic layer for HTTP and for outbound links.
- **The package must stay pure Goose** (`tests/checks/purity.sh`). A loop on epoll needs C, so it lives under `examples/loops/`, the one place the check allows native files and `extern`.
- **Goose constraints** (v2026.4): function values are compile-time, so there is no callback registration; threads share no memory; a root struct cannot be returned; `goose run` cannot link libc externs, so tests of this loop are built with `goose build`.

## Goals / Non-Goals

**Goals:**

- A loop on real sockets that the existing suite and example libraries pass on unchanged, supplying the core and the five groups it is written for (half-close, sizing, abort, inspection and batching). Whether it also supplies the unix group is the owner's decision when the loop is applied (the owner's open decision), and is not assumed here.
- A loop that is tcprouter's code, moved, so that a later tcprouter refactor changes where code lives and not what runs.
- Evidence, before that refactor, that both the handler path and a forwarding extension hold tcprouter's numbers.
- Tests that exist before the code they test and fail when the code is wrong.

**Non-Goals:**

- Changing the contract or the suite. A requirement the loop cannot meet is recorded with what was tried first.
- Changing any file of tcprouter, skein or other repositories.
- Beating tcprouter's numbers. Parity is the gate.
- Portability beyond Linux; io_uring, kqueue and Windows loops are separate changes.

## Decisions

### D1. Where it lives and how it is built

`examples/loops/epoll/` holds the Goose sources, `examples/loops/epoll/sys.c` the C layer (sockets, epoll, pipes, signals, clocks), and `examples/loops/epoll/README.md` how to build. Programs that use it import the contract (`goose_io`) and the loop; nothing in the contract package imports the loop. The first task is a spike that settles how a directory under `examples/loops/` is built with its C file (a build file of its own, or `goose build` flags) and that `goose_io` and the suite are importable from it; the outcome is recorded here.

**Spike result (task 1.1, Goose v2026.4).** A directory under `examples/loops/` builds with its C file from this repository with `goose build`, and no repository of its own is needed. The loop is a package: `examples/loops/epoll/epoll.goose` (`namespace epoll;`) with `epoll.build` beside it (`c_sources = ["src/sys.c"]`, `exclude = ["tests"]`). A program imports the contract and the loop and builds with `goose build`: `import goose_io from "<path to the repository>"; import epoll from "<path to examples/loops/epoll>";` (packages are declared by the root file only, so the loop's own source says `import goose_io;` and the program names where it comes from). The built program printed the clock, and `tests/checks/purity.sh` passes on a copy of the tracked files with the C file there (run in a copy: the local `.implementations/` directory is untracked tooling that the check would otherwise walk).

Alternative considered: a repository of its own. Better for the pure-package rule, worse for running the suite against it in CI of this repository. Kept as the fallback if the spike shows a nested build cannot work.

### D2. tcprouter's code is imported before it is changed

1. Copy the generic files from `05995d1` unmodified, with their tests, in one commit that changes only namespaces and imports. It must build and pass the copied tests; the pass counts are recorded as the behavioural baseline.
2. Move the proxy layer (routes, SNI, forward pump, retry, policy, tags, deadlines, fences) behind the seam, in small commits, each with the imported tests green. The route tags and their leases and deadlines are the proxy layer's own: they move into the extension's per-slot state (D5), and the loop keeps no tag.
3. Move to the contract's names last: `Conn` to `Link`, `send -> bool` to `SendStatus`, events that carry the link and nothing attached to it (no `tag`, no `user`), `Opened` carrying the listener, close reasons to the portable set plus `LoopSpecific`.

Every behaviour change is then a reviewable diff against known-good code, and a failed gate has a bisectable history.

### D3. The work, by group

What the mapping document found, as work (the core first, so that a loop with only the core exists as early as possible):

| Group | Work |
|---|---|
| Core | `listen(address)` at run time (a never-reused `Listener` table, which `Opened` names for an accepted link), `listener_port` (`getsockname`), `tick_by` (one earliest-wake field shared with dial deadlines), `now_ms` exported, `max_send` of at least 4096, `Writable` once the largest refused send fits, `close` that finishes sending and drains input before closing, a slot kept until the handlers of its `Closed` have returned, including for a dial that failed inside `dial` (today the engine frees it when it queues the `Closed`), slots kept dense with a free list (a freed slot is reused before the table is extended, D9), `Closed` reasons mapped to the portable set |
| Half-close | `set_keep_open_on_eof`, `shutdown_write`, `PeerEof` (present in tcprouter) |
| Sizing | `send_room` (present), `send2` (both parts or neither, bounded as the sum) |
| Abort | `reset` (`SO_LINGER` 0) |
| Inspection | `peer_address` (`getpeername`, formatted as the contract's text, valid inside the handler of `Closed`), `stop_listening` |
| Batching | `PassEnd` (present) |

Each row ends with the matching entry point of the suite passing; the loop is described as conforming to a group only when its entry point passes.

### D4. Fixtures for a loop on real sockets

The suite needs three things a contract call cannot make (`docs/event-loops.md`, the fixture): an address where a connect is never answered, an address already held, an address nothing listens on. The loop's runner makes them without privileges: a listener with backlog 1 whose accept queue is filled and never drained (its address drops further connects, so a dial hangs until `connect_ms`), a socket bound and listening that the runner keeps (address in use), and a port that was bound and released (refused). `answers`, for `dial_while_draining`, is a listener the runner keeps accepting. The runner is `examples/loops/epoll/conformance.goose`, and its source is the one quoted in the document of the loop.

### D5. The extension seam

`serve<X, F>(w, x)` takes an extension `x` resolved at compile time; `serve<F>(w)` supplies an empty one. Hooks, each called where tcprouter's proxy code is entered today:

| Hook | Called | Replaces in tcprouter |
|---|---|---|
| `on_accept(w, listener, fd) -> bool` | a socket was accepted; true means the extension took it | `_new_connection` routing and inspection |
| `on_event(w, slot, kind, mask)` | an event for a slot in an extension-owned state or an extension-registered socket | the inspecting, connecting and forwarding arms of `_dispatch_event` |
| `on_ready(w, slot)` | a slot queued by the extension runs after the batch | `_run_ready` calling `_pump` |
| `allows(w, slot) -> bool` | before a dial opens, a send and a flush | `_tag_allows` (the extension looks the slot up in its own state) |
| `on_close(w, slot, reason)` | a slot is being closed | server-socket close, policy notification |
| `on_sweep(w, now)` | the 250 ms sweep | inspect and connect timeouts, deadline enforcement |
| `on_message(w, kind, body)` | a control message the loop does not own | `Deadline`, `CloseTagged`, `SetAddr`, `Policy` |
| `wait_limit(w, now) -> i64` | computing the loop's sleep | tag deadlines in `_wait_limit` |

The loop offers the extension: register and re-arm an extra socket under an extension event kind, take and return a pool buffer, queue a slot for `on_ready`, close a slot with a `LoopSpecific` reason, post extension messages, read the pass clock. Per-slot extension state lives in the extension, indexed by the loop's slot index; the slot's `state` byte has a range for the extension. The extension type must live in a named namespace (found by a spike during the earlier planning).

Why hooks on a generic parameter: tcprouter already does it for policy (`serve<P, F>`), it is monomorphised, and an empty hook compiles to nothing. Alternative: a generic slot payload (`Worker<S>`), which keeps one cache-line pattern but couples the loop's layout to its extension and relies on generic root structs. Held in reserve for D8.

A route's tag, with its lease and deadline, is the extension's own: it lives in per-slot state that the extension keeps, indexed by the link's slot and checked against the generation the extension stores, and the loop carries no tag in any event or operation (contract 0.2 has none). A hook that decides about a link is given its slot. With no extension `allows` is constant true and disappears.

### D6. Timers and clock

One earliest-wake field serves dial deadlines and `tick_by`, generalising tcprouter's `_dial_due`; `Tick` comes at least every 100 ms. There is no timer table. `now_ms` is `CLOCK_BOOTTIME`, read once per pass, as in tcprouter, so it keeps counting through suspend and nothing converts on any path.

### D7. Tests

The suite runs with both ends of every link on the loop, so a mistake that mirrors on both ends passes it. Tcprouter's external drivers (Python processes that talk to the loop over a real socket and observe the wire) are imported with the engine and ported to the contract's names; they run beside the suite and catch what it cannot. The example libraries' scenarios run against real peers in `tests/net/`. A failure in any repetition is a failure until explained.

### D8. Gates and the seam proof

Baseline: tcprouter `05995d1`, `examples/http_hello.goose`, optimised build. Candidate: the same program on this loop.

1. **System calls per request** with `strace -c -f` over a fixed count, equal for `recv`, `send`, `epoll_wait`, `epoll_ctl`, `accept4` and `close`. Deterministic, the primary signal.
2. **Throughput, p99 and CPU per request** with `wrk`, one worker, pinned CPUs, an idle host, at least seven rounds alternating baseline and candidate; the candidate's median must fall within or beat the baseline's own min-to-max range. A run where `wrk` or the backend was the limit is void.
3. **Memory**: idle RSS, RSS with 10,000 idle links and under load, no worse than the baseline and at most 512 bytes per idle link.
4. **Seam proof**: a test extension in `bench/forward_ext/` carries a copy of tcprouter's forward pump with a fixed target and no routing, SNI, retry or policy. It is measured against tcprouter's `forward_server` on 11 B, 16 KiB and 64 KiB keep-alive workloads with gates 1 and 2. If it fails, the seam changes (first candidate: the generic slot payload) before the change is accepted; if no seam reaches parity, the owner decides.

Results, host details and both commits are stored under `bench/results/`.

### D9. Layout

```
examples/loops/epoll/        the loop: worker, links and pool, handler operations, control, address, extension seam, sys.c
examples/loops/epoll/conformance.goose   the runner of the suite with its fixture
tests/net/                   network tests and drivers (Python), run by a script of their own
tests/imported/              tcprouter's tests as imported, until each is ported
bench/                       syscalls, http, memory, forward_ext, results/
```

## Risks / Trade-offs

- **Separating generic from proxy code changes behaviour by accident** → import unmodified first (D2), keep each commit small and the imported suite green.
- **The seam costs something on the forward path** (an extra array access, a call that fails to inline) → measured in D8 before acceptance, with a named alternative.
- **Changes to `Writable`, `close` and the events move the numbers** → the syscall gate is exact, and the throughput gate uses the baseline's own spread.
- **A nested directory may not build with its C file** → the spike (D1) comes first, with a repository of its own as the fallback.
- **Fixtures for a hanging connect and a held port differ between systems** (D4) → they use only the loopback and a full accept queue, checked on the CI systems that run the loop; the loop is Linux-only and its CI job is too.
- **Engine code moves from a private repository to a public one** → requested by the owner of both; only the forward pump is copied from the proxy layer, in `bench/forward_ext/`, and it is reviewed by the owner before any push.
- **Noisy benchmarks** → alternating rounds, void rules, and the deterministic syscall gate first.

## Migration Plan

- Work on a branch of goose-io after `link-keyed-state` (archived) and `lifecycle-guarantees` have merged; nothing is pushed or tagged without the owner's approval. tcprouter's `integrate/goose-io` branch pins an old commit and stays unmerged.
- Rollback is a revert of the merge; the in-memory loop and the suite are untouched.

## Open Questions

- Does a loop under `examples/loops/` build with `goose build` and its C file from this repository (D1), or does it need a repository of its own? Settled by the first task; changes where files are, not what they do.
- Should the loop's multi-worker start use `SO_REUSEPORT` as tcprouter does, or one listener shared by the workers? tcprouter's behaviour is kept unless a test shows a reason.
- Can `Data` be delivered without a copy from a provided-buffer ring in a later io_uring loop? Not for this change.

### D9. Dense slots, held until `Closed` has been handled

Contract 0.2 requires that a freed slot is reused before a new one is issued (so no slot is as large as the greatest number of links valid at once) and that a slot is freed only when every handler of its `Closed` has returned. The loop keeps a free list over its slot table and takes from it before it extends the table. The slot goes back on the list in the place where the engine bumps the generation after delivering `Closed`, not when it queues `Closed` (the engine does the latter today, which is why `peer_address` inside the handler of a `Closed` is empty and a link made there can take the slot, and why a dial that fails inside `dial` loses its slot at once). A slot whose generations are used up is retired and not put back (the rule of `lifecycle-guarantees`). The suite's checks `slots_dense`, `slot_kept_during_closed`, `owner_listener_named`, `owner_dial_found_by_link` and `dial_no_event_inside` are the conformance expectations, and a unit test shows that a link opened inside the handler of a failed dial's `Closed` does not take that slot.

## Applied: what was built, and where it differs from the plan above

Written while applying the change, on the branch `epoll-event-loop`. The plan above stays as it was written; this section says what the code
is and where the owner's instruction at apply time, or what the work found, took it elsewhere.

**The loop was derived directly, not imported and then separated (D2).** The owner's instruction was to make the loop from the current
tcprouter, removing everything of the proxy, so that both engines do the same task in the same way. So there is no import commit of the
unmodified files and no copy of tcprouter's tests under `tests/imported/` (tasks 2.1 to 2.3, 5.3 and 5.4, and the ports of 6.1 are not
done as written). The generic layer of tcprouter's `conn.goose`, `handler.goose`, `engine.goose`, `messages.goose`, `address.goose`,
`sys.goose` and `src/c_sys.c` was edited straight into `examples/loops/epoll/`; what stands in for the imported suite is the conformance suite
(the behaviour of the contract) and the system-call, throughput and memory gates (the behaviour of tcprouter's handler path, which is what
"the same" was to mean). `tests/net/` has new tests, not tcprouter's, apart from the checks of tcprouter's `examples_test.py` that
`http_hello_test.py` repeats.

**The baseline is tcprouter `e021769`, not `05995d1`** (`bench/BASELINE.md`): the owner asked for the current tcprouter. The difference is
the early-close retry of the proxy (`RT-21`), which the loop does not carry; the handler path is as it was.

**There is no extension seam (D5), and so no seam to prove free (D8, point 4).** The owner's instruction was that the forwarding features be
added back to a copy of the loop for the comparison. `examples/loops/forward_ext/epoll_forward/` is that copy: the loop with tcprouter's forward pump
(`forward.goose`) added, a fixed target and nothing of routing, SNI, retry, policy, tags or deadlines (it is under `examples/loops/` because the
purity check allows native files only there). Tasks 5.1 to 5.6 (the seam, its test extensions and `docs/extending.md`), 5.5 and 8.5 (free when
empty) are therefore not done, and the requirements of the delta spec that name an extension (*An extension seam for specialised engines*,
*The seam is free when unused*, *An extension's own identity for a link is its own state*) are not met. If the seam is wanted after all, the
two places a proxy enters the loop are `_dispatch_event` and `serve` (see `docs/tcprouter-adoption.md`); the comparison of 9.2 and 9.3 held on the
first try, so the reserved alternative of 9.4 (a generic slot payload) was not needed.

**Decisions the work made.**

- *Close.* The design's D3 says `close` keeps the link in a closing state that reads and drops input. The suite showed that is not enough: the check
  `states_inspection` needs the closing side's `Closed` before the peer's, and a link held until the peer ends also holds its slot. So `close` finishes
  sending, shuts the write side and ends the link at once (the `Closed`, reason `Local`, is delivered after the handler that called it has returned),
  and the socket is kept as an orphan (`_Orphan`: a descriptor and a time, no slot, no event) that reads and drops the peer's input until the peer
  ends its stream or `half_close_timeout_ms` passes. The peer sees an end of stream and never a reset. Both `close_with_unread_input` (suite) and
  `tests/net/close_test.py` fail if the loop does a plain `close(2)` there.
- *`peer_address` inside the handler of `Closed`.* The descriptor is closed only when the `Closed` has been handled (`_release`). A socket forgets its
  peer once it has been reset or both directions have finished, so the address is asked for (`getpeername`) just before a reset is reported, before
  `shutdown` of the write side, and in no other case: it costs no system call on the path of a request.
- *Peer end of stream.* The loop does not decide what the end of the peer's stream means when it reads it: it queues a record, and the decision (end the
  link, or `PeerEof`) is taken when the record is reached, after the handler of `Opened` has returned, so that `set_keep_open_on_eof` in that handler
  applies even if the stream had already ended. Nothing is registered with epoll differently in the usual case (one `epoll_ctl` per connection fewer than the
  first version, which the system-call gate caught).
- *Ticks.* The loop aims at 90 ms between Ticks (`_TICK_PERIOD_MS`), not 100: `ticks_are_regular` allows at most 100 ms between two, and a 100 ms
  wait plus the millisecond rounding of `epoll_wait` and the scheduler gave 101 and 102. D6's one earliest-wake field is two (`_dial_due` for connects,
  `_wake_at` for `tick_by`); the wait is the least of them and of the next Tick.
- *Slots.* A free list gives a freed slot to the next link before the table is extended; a slot is freed (and its generation advanced) after its `Closed` has
  been handled, and retired when its 24-bit generation is used up (the epoll data carries 24 bits).
- *Writable.* A link remembers the largest send it refused and gets its one `Writable` when `send_room` reaches that. A send that waits for a pool buffer
  is counted in `buffer_waits`, as a read that waits is.
- *Limits and workers.* `listen` uses `SO_REUSEPORT` (as tcprouter does) so that loops share a port; `epoll::probe(address)` is the plain bind that tcprouter's
  `spawn` did, to be called before `spawn`, so that a port held by another process is an error.
- *The unix group is not supplied* (the open decision of the proposal): a `unix:` address is `BadAddress`.
- *Fixture.* `examples/loops/epoll/conformance.goose` gives the suite its four addresses in one array: the language refuses to call a loop that shrinks one of
  its own arrays while the suite holds views of several arrays, so the loop's arrays that shrink are grow-shrink (`[>..<]`) and the fixture is four slices of one.
