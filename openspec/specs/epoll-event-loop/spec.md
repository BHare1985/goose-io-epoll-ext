# epoll-event-loop Specification

## Purpose
The reference Linux epoll event loop of the I/O contract: workers that share nothing, derived from tcprouter's engine, that libraries run on directly on real sockets and that a specialised engine such as tcprouter can extend without losing behaviour or speed.

## Requirements

### Requirement: The loop supplies the core and its five groups and passes the suite
The epoll event loop SHALL supply every operation and event of the core and of the half-close, sizing, abort, inspection and batching groups (whether it also supplies the unix group is decided when it is applied), and SHALL pass the core and each group of the conformance suite on Linux. It SHALL call the contract's checks for the core and for each group from its root program.

#### Scenario: The suite passes by group
- **WHEN** the core and each group of the conformance suite are run against the epoll event loop on Linux
- **THEN** every check of every part passes, in fifty repetitions

#### Scenario: A missing operation is a compile error
- **WHEN** an operation of a group the loop claims is removed from it
- **THEN** its root program fails to build and the error names the operation

### Requirement: The example libraries run on real sockets
The example line server and line client SHALL run on the epoll event loop with no change to their source, and the same scenarios that pass on the in-memory loop SHALL pass against real peers.

#### Scenario: A line client against a real service
- **WHEN** the line client runs on the epoll loop against a line service that is restarted while the client runs
- **THEN** requests are answered or time out as on the in-memory loop, and the client dials again after its backoff

#### Scenario: Both libraries on one worker
- **WHEN** the line server and the line client run on one worker, tagged differently, and the server answers each request with a reply fetched through the client
- **THEN** every request is answered, in order, and each library handles only its own events

### Requirement: One share-nothing worker per thread
Each worker SHALL own its event loop, links, buffers and tables and share no memory with another. Several workers SHALL be able to listen on one address, the kernel distributing connections among them. Starting a worker on an address that fails SHALL report a message naming the address and the system's error and SHALL NOT abort the process.

#### Scenario: Several workers share a port
- **WHEN** four workers listen on one address and four hundred connections arrive
- **THEN** each connection is accepted by exactly one worker and the accepted counts sum to four hundred

#### Scenario: A port held by another process
- **WHEN** a worker is started on an address another process listens on
- **THEN** start-up fails with a message naming the address, and the port is not shared with that process

### Requirement: Peers and the kernel cannot crash a worker
A worker SHALL NOT abort or exit because of anything a peer sends or does, or because the kernel reports an event for an unknown slot, an unknown kind or an outdated generation. Such events SHALL be counted and otherwise ignored, and every affected link SHALL end with exactly one `Closed`.

#### Scenario: An event for a closed link
- **WHEN** the kernel reports an event for a link that has closed and whose slot was reused
- **THEN** the new link is unaffected and the stale-event counter increases by one

#### Scenario: Hostile peers
- **WHEN** peers connect and reset, send partial data and vanish, or half-close at arbitrary points, thousands of times
- **THEN** the worker keeps serving other links

### Requirement: Limits are enforced without spinning
A worker SHALL accept limits for links, read buffer size, buffers, and connect, idle and half-close timeouts. When accepting runs out of descriptors or memory it SHALL count the failure and rest that listener briefly, SHALL NOT busy-loop, and SHALL accept pending connections once resources return.

#### Scenario: Descriptor exhaustion
- **WHEN** the descriptor limit is reached while connections keep arriving
- **THEN** the worker's CPU use stays far below one core, the accept-failure counter rises, and waiting connections are accepted after descriptors are freed

#### Scenario: The link limit
- **WHEN** a dial would exceed the links per worker
- **THEN** that link receives one `Closed` with reason `ConnectFailed` of kind `NoResources` and the other links are unaffected

### Requirement: Idle links hold no buffer
A link with no bytes in flight SHALL hold no read or send buffer. Buffers SHALL come from a per-worker pool, created lazily, that never moves a buffer in use. When the pool is empty, reads and refused sends SHALL wait in arrival order for a buffer, and the wait SHALL be counted.

#### Scenario: Memory per idle link
- **WHEN** ten thousand links are open and idle on one worker
- **THEN** resident memory has grown by at most 512 bytes per link over the idle worker

#### Scenario: Pool exhaustion delays and loses nothing
- **WHEN** stalled links hold every buffer of a small pool and other links have data to read
- **THEN** the others wait, the buffer-wait counter rises, and their data is delivered intact once buffers return

### Requirement: Timeouts are enforced within one sweep
A link that has moved no bytes either way for the idle timeout SHALL be closed with `IdleTimeout`, a half-closed link outliving the half-close timeout with `HalfCloseTimeout`, and a dial outliving its connect time with `ConnectFailed` of kind `TimedOut`. Idle and half-close closes SHALL be no earlier than the limit and no later than the limit plus 250 ms.

#### Scenario: Idle timeout
- **WHEN** the idle timeout is one second and a link carries no bytes
- **THEN** it is closed with `IdleTimeout` between 1.0 and 1.25 seconds after its last byte

#### Scenario: Activity resets the idle timer
- **WHEN** bytes move on a link in either direction, including bytes a library sends
- **THEN** the idle period is measured from that moment

### Requirement: Close does not reset a link with unread input
`close` SHALL finish sending what was accepted, then end the connection so that input received but not delivered does not cause the peer to lose bytes already sent to it, discarding that input until the peer's end of stream or a limit of the loop's own.

#### Scenario: Close with unread input
- **WHEN** a library sends a reply and calls `close` while the peer has sent more bytes that were not read
- **THEN** the peer receives the whole reply and then end of stream, not a reset

#### Scenario: A peer that never reads
- **WHEN** a library calls `close` on a link whose peer reads nothing
- **THEN** the link's `Closed` with reason `Local` is delivered after the loop's limit, and the worker holds no more memory for it

### Requirement: Drain
A drain request SHALL reach every worker exactly once and be handled before the network events of the same pass. A draining worker SHALL stop listening at once, let open links finish, close those still open at the deadline with `Shutdown`, deliver their `Closed` events, and return from its loop. A helper SHALL wait for a termination signal and then drain all workers.

#### Scenario: Drain with nothing open
- **WHEN** a drain is requested while no link is open
- **THEN** every worker stops listening and returns from its loop promptly

#### Scenario: Drain with a stuck link
- **WHEN** a drain with a two-second deadline is requested while one link stays open
- **THEN** new connections are refused at once, the link receives `Closed` with reason `Shutdown` at the deadline, and the worker then returns

### Requirement: Statistics
Each worker SHALL keep counters for accepted, open and closed links by reason, bytes in and out, connect failures, buffers in use, buffer waits, stale and invalid events, and accept failures, readable as a snapshot on the worker's own thread. A request to gather statistics SHALL return the sum over all workers.

#### Scenario: Counters are exact across workers
- **WHEN** a known number of connections is opened and closed across four workers and statistics are gathered
- **THEN** the summed accepted and closed counts equal the number of connections

### Requirement: Behaviour matches tcprouter's handler mode
For links handled by a library, the loop SHALL behave as tcprouter's handler mode at the commit it is derived from: the tcprouter tests of handler, dialled and half-closed links, pass-end, send queues, backpressure, generations, timeouts and drain SHALL pass once ported to the contract's names, or a difference SHALL be recorded in the design with its cause.

#### Scenario: Ported handler tests
- **WHEN** those tests are run against the loop
- **THEN** every check passes, or each difference is recorded with its cause before the change is accepted

### Requirement: Performance is no worse than tcprouter on the same workload
On one host and method, a keep-alive HTTP server on the loop SHALL make the same number of each system call per request as the equivalent tcprouter server at the baseline commit, and its throughput, 99th-percentile latency and CPU per request SHALL be no worse than the baseline beyond the baseline's own run-to-run spread.

#### Scenario: System calls per request
- **WHEN** the keep-alive workload is traced for both servers
- **THEN** the counts of `recv`, `send`, `epoll_wait`, `epoll_ctl`, `accept4` and `close` per request are equal

#### Scenario: Throughput, latency and CPU
- **WHEN** both servers are measured over alternating rounds on an idle host
- **THEN** the loop's medians fall within, or beat, the range of the baseline's own repeated runs

#### Scenario: A forwarding loop holds tcprouter's numbers
- **WHEN** a copy of the loop carrying tcprouter's forward pump (goose-io-epoll-ext) is measured against tcprouter's forwarding server on small, 16 KiB and 64 KiB keep-alive workloads
- **THEN** system calls per request are equal and the medians fall within, or beat, the baseline's range

#### Scenario: A regression blocks acceptance
- **WHEN** any of these measurements is worse than the baseline's range
- **THEN** the change is not accepted until the cause is found and removed

### Requirement: The loop attaches nothing to a link
The epoll event loop SHALL offer the operations and deliver the events of contract 0.2 only: `listen(address)`, `dial(address, connect_ms)`, and events that carry the link (and, for `Opened`, the listener that accepted it), with no tag, no user value and no operation that sets or reads one. A library SHALL find its state from the link of an event.

#### Scenario: A library on the loop uses no tag
- **WHEN** the example line server and line client run on the loop with no tag assigned by the application
- **THEN** each handles only the events of its own links, and the checks that an accepted link names its listener and that a dial that fails at once is found by its link pass

#### Scenario: An operation that was removed does not exist
- **WHEN** a library calls `set_user` or passes a tag to `listen` or `dial` on the loop
- **THEN** the build fails and the error names the call

### Requirement: Slots are dense and held until Closed has been handled
The epoll event loop SHALL give a new link a freed slot before it gives a slot it has never used, and SHALL free a slot only when every handler of its link's `Closed` has returned. A slot whose generations are used up MAY be retired.

#### Scenario: Freed slots are reused first
- **WHEN** a program opens eight links on the loop, closes them all, waits for every `Closed`, and opens eight more
- **THEN** every link of the second eight has a slot below eight

#### Scenario: A slot is not reused inside the handler of its Closed
- **WHEN** a handler receives `Closed` for a link and opens a new link before it returns
- **THEN** the new link does not take the slot of the link being closed, including when the closed link was a dial that failed inside `dial`
