// The forwarding server of the seam proof: the epoll event loop with tcprouter's forward pump added back (epoll_ext/forward.goose),
// forwarding every connection of its listener to one target. It takes the flags of tcprouter's tests/net/harness/forward_server.goose
// that the gates and the correctness checks use:
//
//     forward_server --listen 127.0.0.1:9000 --to 127.0.0.1:9100 [--workers 1] [--buffers 4096] [--buffer-size 32768] [--stat-ms N]
//
// Prints READY at start and a STAT line every --stat-ms (tcprouter's harness format). Stops on SIGTERM or SIGINT, draining for up to five seconds.
import std;
import os;
import goose_io from "github.com/BHare1985/goose-io@v0.4";
import epoll_ext from ".";

var pending_listen: u8[>..] = [];
var routes:      u8[>..] = []; // "listen=target" lines, each ended by a newline
var buffers:     i64     = 4096;
var buffer_size: i64     = 32768;
var stat_ms:     i64     = 1000;
var connect_timeout_ms: i64 = 2000;
var idle_timeout_ms: i64 = 0;
var half_close_timeout_ms: i64 = 0;
var control_mode: bool = false;

// The reasons in tcprouter's order (PeerClosed, PeerReset, IdleTimeout, HalfCloseTimeout, InspectTimeout, ConnectFailed, Fenced, Drained,
// ByHandler, Error, InvalidHello), so the tests written against tcprouter read them unchanged; the ones a loop has no such reason for are 0.
fn put_closed(line: u8[>..]&, s: epoll_ext::Stats) {
    let c = s.closed;                  // ext order: PeerClosed, PeerReset, ConnectFailed, IdleTimeout, HalfCloseTimeout, Local, Shutdown, Error, LoopSpecific
    format(line, c[0], ",", c[1], ",", c[3], ",", c[4], ",0,", c[2], ",0,", c[6], ",", c[5], ",", c[7], ",0");
}

fn print_totals(s: epoll_ext::Stats) {
    var line: u8[>..] = [];
    format(line, "TOTAL accepted=", s.accepted, " open=", s.open, " bytes_in=", s.bytes_in, " bytes_out=", s.bytes_out,
           " connect_failures=", s.connect_failures, " retries=0 closed=");
    put_closed(line, s);
    format(line, " tags=");
    print(line);
}

extern fn read(fd: i32, buf: u8&, n: u64) -> i64;

var WORKERS: i64 = 1;
var drain_ms: i64 = 5000;

// stdin commands, as tcprouter's harness had them: `drain MS` and `stats` (the rest are router features).
fn run_command(line: const u8[:]) {
    if line == "stats" { print_totals(epoll_ext::gather_stats(WORKERS)); return; }
    if line.len > 6 && line[..6] == "drain " {
        let ms, ok = parse_int(line[6..]);
        if ok { epoll_ext::drain(ms); }
    }
}

thread_fn control() {
    var pending: u8[>..] = [];
    var chunk: u8[256] = [0; 256];
    loop {
        let n = read(0, chunk[0], 256);
        if n <= 0 { return; }
        pending.append(chunk[..n]);
        loop {
            var nl: i64 = -1;
            for k in pending.len { if pending[k] == 10 { nl = k; break; } }
            if nl < 0 { break; }
            run_command(pending[..nl]);
            let rest = pending.len - nl - 1;
            for k in rest { pending[k] = pending[nl + 1 + k]; }
            pending.pop_n(nl + 1);
        }
    }
}

fn print_stats(io: epoll_ext::Loop&, index: i64) {
    let s = io.stats();
    var line: u8[>..] = [];
    format(line, "STAT ", index, " accepted=", s.accepted, " open=", s.open, " bytes_in=", s.bytes_in, " bytes_out=", s.bytes_out,
           " connect_failures=", s.connect_failures, " buffers_total=", s.buffers_total, " buffers_in_use=", s.buffers_in_use,
           " buffer_waits=", s.buffer_waits, " stale_events=", s.stale_events, " bad_events=", s.bad_events,
           " accept_failures=", s.accept_failures, " ready_len=", s.ready_len, " waiting_len=", s.waiting_len, " closed=");
    put_closed(line, s);
    print(line);
}

fn on_event(io: epoll_ext::Loop&, ev: goose_io::Event, index: i64, every: i64, last: i64&) {
    match ev {
        Tick t => {
            io.tick_by(t.now_ms + 100);
            if t.now_ms - last >= every { last = t.now_ms; print_stats(io, index); }
        },
        _ => {},
    }
}

thread_fn worker(index: i64) {
    var io = epoll_ext::Loop { .. };
    io.limits.buffers_per_loop = buffers;
    io.limits.buffer_size = buffer_size;
    io.limits.connect_timeout_ms = connect_timeout_ms;
    if idle_timeout_ms > 0 { io.limits.idle_timeout_ms = idle_timeout_ms; }
    if half_close_timeout_ms > 0 { io.limits.half_close_timeout_ms = half_close_timeout_ms; }
    var from: i64 = 0;
    while from < routes.len {
        var end = from;
        while routes[end] != 10 { end++; }
        var eq = from;
        while routes[eq] != 61 { eq++; }
        let listen_addr = routes[from..eq];
        var tend = eq + 1;
        while tend < end && routes[tend] != 44 { tend++; } // only the first target of a route list
        let target_addr = routes[eq + 1..tend];
        from = end + 1;
        let l, err = io.listen(listen_addr);
        if goose_io::failed(err) { print("cannot listen on ", listen_addr); epoll_ext::report_failed_start(); return; }
        if !epoll_ext::forward_from(io, l, target_addr) { print("bad target ", target_addr); epoll_ext::report_failed_start(); return; }
    }
    io.attach(index);
    print("READY ", index);
    io.tick_by(io.now_ms() + 100);
    var last: i64 = 0;
    let every = stat_ms;
    io.serve() { io, ev => on_event(io, ev, index, every, last); };
}

fn main() {
    var workers = 1;
    var k = 1;
    while k < arg_count() {
        var flag: u8[>..] = [];
        arg(k, flag);
        var value: u8[>..] = [];
        if flag == "--control" { control_mode = true; k += 1; continue; }
        if k + 1 < arg_count() { arg(k + 1, value); }
        k += 2;
        let n, ok = parse_int(value[..]);
        if flag == "--listen" { pending_listen.append(value[..]); pending_listen.append("\n"); }
        else if flag == "--to" {                         // every listener given so far forwards to this target
            var at: i64 = 0;
            while at < pending_listen.len {
                var e = at;
                while pending_listen[e] != 10 { e++; }
                routes.append(pending_listen[at..e]); routes.append("="); routes.append(value[..]); routes.append("\n");
                at = e + 1;
            }
        }
        else if flag == "--route" { routes.append(value[..]); routes.append("\n"); }
        else if flag == "--workers" && ok { workers = n; }
        else if flag == "--buffers" && ok { buffers = n; }
        else if flag == "--buffer-size" && ok { buffer_size = n; }
        else if flag == "--stat-ms" && ok { stat_ms = n; }
        else if flag == "--connect-timeout-ms" && ok { connect_timeout_ms = n; }
        else if flag == "--idle-timeout-ms" && ok { idle_timeout_ms = n; }
        else if flag == "--half-close-timeout-ms" && ok { half_close_timeout_ms = n; }
        else if flag == "--drain-ms" && ok { drain_ms = n; }
    }
    WORKERS = workers;
    // A port held by another process is an error naming the address and why, not loops quietly sharing it (RT-1d).
    var from: i64 = 0;
    while from < routes.len {
        var end = from;
        while routes[end] != 10 { end++; }
        var eq = from;
        while routes[eq] != 61 { eq++; }
        let perr = epoll_ext::probe(routes[from..eq]);
        if goose_io::failed(perr) {
            var text: u8[>..] = [];
            epoll_ext::describe_listen_failure(routes[from..eq], perr, text);
            text.append("\n");
            write_stderr(text[..]);
            exit(1);
        }
        from = end + 1;
    }
    let ids = epoll_ext::spawn(workers, worker);
    if control_mode {
        thread_spawn(control);
        for id in ids { thread_wait(id); }               // returns when stdin's `drain MS` has ended every loop
    } else {
        epoll_ext::wait_for_signal_then_drain(drain_ms);
    }
}
