// The epoll event loop of goose-io: the contract (`goose_io`) on real sockets, on Linux, one `Loop` per thread.
//
//     import goose_io from "github.com/BHare1985/goose-io@apply-name-resolution";
//     import epoll from "github.com/BHare1985/goose-io-epoll-ext";
//
// It supplies the core and ten capabilities of contract 0.4, declared at the end of proxy_capabilities.goose: half_close, sizing, abort,
// inspection, batching, relay, peek, revoke, wake and limits (not unix). A program that runs libraries on it calls `goose_io::require_core(io)` and the check of each capability from its root.
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
import .proxy_capabilities;
