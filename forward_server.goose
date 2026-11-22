// The forwarding server of the seam proof: the epoll event loop with tcprouter's forward pump added back (epoll_ext/forward.goose),
// forwarding every connection of its listener to one target. It takes the flags of tcprouter's tests/net/harness/forward_server.goose
// that the gates and the correctness checks use:
//
//     forward_server --listen 127.0.0.1:9000 --to 127.0.0.1:9100 [--workers 1] [--buffers 4096] [--buffer-size 32768] [--stat-ms N]
//
// Prints READY at start and a STAT line every --stat-ms (tcprouter's harness format). Stops on SIGTERM or SIGINT, draining for up to five seconds.
import std;
import os;
import goose_io from "github.com/BHare1985/goose-io@bfadab427f4ac37a89d9182fbd943d0c9e0d7457";
import epoll_ext from ".";

var pending_listen: u8[>..] = [];
var routes:      u8[>..] = []; // "listen=target" lines, each ended by a newline
var buffers:     i64     = 4096;
var buffer_size: i64     = 32768;
var stat_ms:     i64     = 1000;

fn print_stats(io: epoll_ext::Loop&, index: i64) {
    let s = io.stats();
    var line: u8[>..] = [];
    format(line, "STAT ", index, " accepted=", s.accepted, " open=", s.open, " bytes_in=", s.bytes_in, " bytes_out=", s.bytes_out,
           " connect_failures=", s.connect_failures, " buffers_total=", s.buffers_total, " buffers_in_use=", s.buffers_in_use,
           " buffer_waits=", s.buffer_waits, " stale_events=", s.stale_events, " bad_events=", s.bad_events,
           " accept_failures=", s.accept_failures, " ready_len=", s.ready_len, " waiting_len=", s.waiting_len);
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
        if k + 1 < arg_count() { arg(k + 1, value); }
        k += 2;
        let n, ok = parse_int(value[..]);
        if flag == "--listen" { pending_listen.clear(); pending_listen.append(value[..]); }
        else if flag == "--to" { routes.append(pending_listen[..]); routes.append("="); routes.append(value[..]); routes.append("\n"); }
        else if flag == "--route" { routes.append(value[..]); routes.append("\n"); }
        else if flag == "--workers" && ok { workers = n; }
        else if flag == "--buffers" && ok { buffers = n; }
        else if flag == "--buffer-size" && ok { buffer_size = n; }
        else if flag == "--stat-ms" && ok { stat_ms = n; }
    }
    epoll_ext::spawn(workers, worker);
    epoll_ext::wait_for_signal_then_drain(5000);
}
