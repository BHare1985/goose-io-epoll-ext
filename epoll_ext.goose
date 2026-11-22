// The epoll event loop of goose-io: the contract (`goose_io`) on real sockets, on Linux, one `Loop` per thread.
//
//     import goose_io from "github.com/BHare1985/goose-io@bfadab427f4ac37a89d9182fbd943d0c9e0d7457";
//     import epoll from "github.com/BHare1985/goose-io-epoll-ext";
//
// It supplies the core and the half-close, sizing, abort, inspection and batching groups of contract 0.2 (not the unix group). A program
// that runs libraries on it calls `goose_io::require_core(io)` and the check of each group from its root, as docs/event-loops.md says.
// It is built with `goose build` (the C layer is src/sys.c, named in epoll.build); `goose run` cannot link it.
//
// Layout (every file declares `namespace epoll;`; names starting with `_` and `c_` are internal):
//
//     engine.goose    the Loop: links, buffers, sending, dialling, timeouts, serve
//     messages.goose  running several loops, one per thread: spawn, drain, statistics
//     address.goose   "ip:port" as sockets want it, and as the contract writes it
//     config.goose    Limits
//     sys.goose       the C layer's declarations (src/sys.c)
namespace epoll_ext;

import .sys;
import .config;
import .address;
import .engine;
import .messages;
import .forward;
import .groups;
