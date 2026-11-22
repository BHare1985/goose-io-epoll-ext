// Forwarding, added back to the epoll event loop for the seam proof (goose-io-epoll-ext). This is tcprouter's forward pump (conn.goose:
// `_pump`, `_pump_direction`, `_write_buffer`, `_run_ready`, `_connect_finished` and the forwarding arm of `_dispatch_event`) with a fixed
// target: no routes, no SNI inspection, no retry, no policy, no tags, no deadlines. A link accepted on the forwarding listener is not a
// contract link: it has no Opened and no Closed, and the loop moves its bytes to the target and back by itself, as tcprouter's does.
//
// COPIED FROM A PRIVATE REPOSITORY (tcprouter). Owner review is required before this file is pushed anywhere public.
//
// Forwarded sockets are registered with epoll ONCE, edge-triggered (EPOLLIN|OUT|RDHUP|ET), and never modified again: an event only sets a
// readiness flag in the link, and `_pump` moves bytes until a flag runs out (recv or send says EAGAIN, or a short read drained the
// socket). A pump that stops because of its byte budget puts the link on the ready list, because an edge will not be reported again.
namespace epoll_ext;

import std;
import goose_io;
import .sys;
import .address;
import .config;
import .engine;

let _CONNECTING: u8 = 4;             // the connect to the target is in progress; the client is not read yet
let _FORWARDING: u8 = 5;

let _EVENT_KIND_SERVER: u64 = 5;
let _WAITER_FWD_UP:     u64 = 6;     // a forwarded read waits for a pool buffer: client to server
let _WAITER_FWD_DOWN:   u64 = 7;     // server to client

let _READY_CLIENT_IN:    u8 = 1;
let _READY_CLIENT_OUT:   u8 = 2;
let _READY_SERVER_IN:    u8 = 4;
let _READY_SERVER_OUT:   u8 = 8;
let _READY_CLIENT_ENDED: u8 = 16;
let _READY_SERVER_ENDED: u8 = 32;

let _WAKEUP_BUDGET: i64 = 65536;      // bytes one direction may move per wakeup before others get a turn

// One direction of a forwarded link. It owns at most ONE pool buffer, and only while it holds bytes it has read but not yet written.
struct _Direction {
    buf:     i32  = -1,
    len:     i32  = 0,
    pos:     i32  = 0,
    eof:     bool = false,
    shut:    bool = false,
    waiting: bool = false,
}

// Makes the listener a forwarding one: every connection it accepts is connected to `target` and pumped.
fn forward_from(io: Loop&, l: goose_io::Listener, target: const u8[:]) -> bool {
    var p = _ParsedAddress { false, [0; 16], 0 };
    if !_parse_address(target, p, false) { return false; }
    io._fwd_routes.append([_FwdRoute { l.id, p }]);
    true
}

struct _FwdRoute { listener: u32, target: _ParsedAddress }

// Index of the forwarding route of listener `id`, or -1.
fn _fwd_route_of(io: Loop&, id: u32) -> i64 {
    for r in io._fwd_routes.len { if io._fwd_routes[r].listener == id { return r; } }
    -1
}

fn _is_forwarded(s: _Link&) -> bool { s.state == _CONNECTING || s.state == _FORWARDING }

fn _flag_readable(up: bool) -> u8 { if up { _READY_CLIENT_IN } else { _READY_SERVER_IN } }
fn _flag_writable(up: bool) -> u8 { if up { _READY_SERVER_OUT } else { _READY_CLIENT_OUT } }
fn _flag_ended(up: bool) -> u8 { if up { _READY_CLIENT_ENDED } else { _READY_SERVER_ENDED } }
fn _forget(s: _Link&, flag: u8) { s.ready = s.ready & (255 - flag); }

fn _direction_of(s: _Link&, up: bool) -> _Direction& {
    if up { return s.up; }
    s.down
}

// An accepted socket on the forwarding listener: join epoll edge-triggered, then connect to the target.
fn _start_forward(io: Loop&, i: i64, route: i64) {
    let s .= io._links[i];
    s.state = _CONNECTING;
    let mask = c_EPOLLIN | c_EPOLLOUT | c_EPOLLRDHUP | c_EPOLLET;
    if c_epoll_ctl(io._epoll_fd, c_EPOLL_CTL_ADD, s.fd, mask, _pack_event_data(_EVENT_KIND_LINK, i, s.gen)) < 0 { io._end_forward(i, goose_io::CloseReason.Error); return; }
    s.registered = true;
    s.mask = mask;
    s.started_ms = io._now_ms;
    let sfd = c_connect_start(io._fwd_routes[route].target.v6, io._fwd_routes[route].target.ip, io._fwd_routes[route].target.port);
    if sfd < 0 { io._stats.connect_failures++; io._end_forward(i, goose_io::CloseReason.ConnectFailed { kind: _connect_kind(-sfd) }); return; }
    s.server_fd = sfd;
    s.server_mask = c_EPOLLIN | c_EPOLLOUT | c_EPOLLRDHUP | c_EPOLLET;
    if c_epoll_ctl(io._epoll_fd, c_EPOLL_CTL_ADD, sfd, s.server_mask, _pack_event_data(_EVENT_KIND_SERVER, i, s.gen)) < 0 { io._end_forward(i, goose_io::CloseReason.Error); }
}

// Closes both sockets, returns the buffers and frees the slot at once (a forwarded link has no Closed to wait for).
fn _end_forward(io: Loop&, i: i64, reason: goose_io::CloseReason) {
    let s .= io._links[i];
    if !s._is_forwarded() { return; }
    if s.fd >= 0 { c_close(s.fd); s.fd = -1; }
    if s.server_fd >= 0 { c_close(s.server_fd); s.server_fd = -1; }
    let up_buf = s.up.buf;
    let down_buf = s.down.buf;
    s.up = _Direction { .. };
    s.down = _Direction { .. };
    s.state = _FREE;
    s.registered = false;
    s.mask = 0;
    s.gen = s.gen + 1;
    io._live--;
    io._stats.open--;
    io._stats.closed[_reason_index(reason)]++;
    if s.gen <= _MAX_GEN { io._free_links.push(i as u32); }
    if up_buf >= 0 { io._give_back_buffer(up_buf); }
    if down_buf >= 0 { io._give_back_buffer(down_buf); }
}

fn _connect_finished(io: Loop&, i: i64) {
    let s .= io._links[i];
    let err = c_connect_result(s.server_fd);
    if err != 0 {
        io._stats.connect_failures++;
        io._end_forward(i, goose_io::CloseReason.ConnectFailed { kind: _connect_kind(err) });
        return;
    }
    s.state = _FORWARDING;
    s.ready |= _READY_SERVER_OUT;                          // a finished connect is writable; its edge was this event
    io._pump(i);
}

// Adds a link to the ready list: it has work left that no event will announce.
fn _queue_ready(io: Loop&, i: i64) {
    let s .= io._links[i];
    if s.state == _FREE || s.queued { return; }
    s.queued = true;
    io._ready.push(_pack_event_data(0, i, s.gen));
}

// Runs the links queued so far (those queued meanwhile wait for the next pass, so nobody is starved).
fn _run_ready(io: Loop&) {
    let end = io._ready.len;
    while io._ready_head < end {
        let e = io._ready[io._ready_head];
        io._ready_head++;
        let slot = (e >> 32) as i64;
        let gen = ((e >> 8) & 0xffffff) as u32;
        let s .= io._links[slot];
        if s.state != _FREE && s.gen == gen {
            s.queued = false;
            if s.state == _FORWARDING { io._pump(slot); }
        }
    }
    let left = io._ready.len - io._ready_head;
    if left == 0 {
        io._ready.clear();
        io._ready_head = 0;
    } else if io._ready_head > 0 {
        for k in left { io._ready[k] = io._ready[io._ready_head + k]; }
        io._ready.pop_n(io._ready_head);
        io._ready_head = 0;
    }
}

// Moves bytes in both directions as far as the readiness flags allow.
fn _pump(io: Loop&, i: i64) {
    let s .= io._links[i];
    let more_up = io._pump_direction(i, true);
    if s.state == _FREE { return; }
    let more_down = io._pump_direction(i, false);
    if s.state == _FREE { return; }
    if more_up || more_down { io._queue_ready(i); }
}

// Reads from the source and writes to the destination of one direction (`up`: client to server) until one of them has nothing more to
// give or take. True when it stopped only because it moved _WAKEUP_BUDGET bytes (the connection is queued to go on).
fn _pump_direction(io: Loop&, i: i64, up: bool) -> bool {
    let s .= io._links[i];
    let dir .= s._direction_of(up);
    let src = if up { s.fd } else { s.server_fd };
    let dst = if up { s.server_fd } else { s.fd };
    let readable = _flag_readable(up);
    let writable = _flag_writable(up);
    var moved: i64 = 0;
    loop {
        if dir.len > dir.pos {                                        // bytes read but not written yet
            if (s.ready & writable) == 0 { return false; }            // destination full: its writable edge restarts us
            if !io._write_buffer(i, up, dst) { return false; }
        }
        if dir.eof || dir.waiting { return false; }
        if (s.ready & readable) == 0 { return false; }
        if moved >= _WAKEUP_BUDGET { return true; }

        let b = io._take_buffer();
        if b < 0 {                                                    // pool empty: wait, do not read
            dir.waiting = true;
            io._waiting_reads.push(_pack_event_data(if up { _WAITER_FWD_UP } else { _WAITER_FWD_DOWN }, i, s.gen));
            io._stats.buffer_waits++;
            return false;
        }
        dir.buf = b;
        let buf = io._buffer_slice(b);
        let n = c_recv(src, buf[0], buf.len);
        if n > 0 {
            dir.len = n as i32;
            dir.pos = 0;
            moved += n;
            s.last_active_ms = io._now_ms;
            // A short read means the socket is drained, unless its peer already ended: then the next read says so.
            if n < buf.len && (s.ready & _flag_ended(up)) == 0 { s._forget(readable); }
            continue;
        }
        // Nothing to keep: give the buffer back before anything else.
        let held = dir.buf;
        dir.buf = -1;
        dir.len = 0;
        dir.pos = 0;
        io._give_back_buffer(held);
        if n == 0 {                                                   // the source ended: tell the destination, stop reading
            dir.eof = true;
            if s.half_closed_at_ms == 0 { s.half_closed_at_ms = io._now_ms; }
            s._shutdown_unless_closing(up, dst);
            dir.shut = true;
            if s.up.eof && s.up.shut && s.down.eof && s.down.shut { io._end_forward(i, goose_io::CloseReason.PeerClosed); }
            return false;
        }
        if n == -(c_EAGAIN as i64) { s._forget(readable); return false; }
        if n == -(c_EINTR as i64) { return true; }                    // interrupted: try again on the next pass
        io._end_forward(i, goose_io::CloseReason.PeerReset);
        return false;
    }
}

// Writes what a direction holds. True when all of it went out (the buffer is back in the pool); false when the destination is full
// (its writable flag is cleared) or the link was ended.
fn _write_buffer(io: Loop&, i: i64, up: bool, dst: i32) -> bool {
    let s .= io._links[i];
    let dir .= s._direction_of(up);
    while dir.pos < dir.len {
        let buf = io._buffer_slice(dir.buf);
        let rest = buf[dir.pos..dir.len];
        let n = c_send(dst, rest[0], rest.len);
        if n > 0 {
            dir.pos += n as i32;
            s.last_active_ms = io._now_ms;
            if up { io._stats.bytes_in += n; } else { io._stats.bytes_out += n; }
        } else if n == -(c_EAGAIN as i64) {
            s._forget(_flag_writable(up));
            return false;
        } else if n != -(c_EINTR as i64) {
            io._end_forward(i, goose_io::CloseReason.PeerReset);
            return false;
        }
    }
    // Everything written: the buffer goes back, so an idle connection holds none.
    let held = dir.buf;
    dir.buf = -1;
    dir.len = 0;
    dir.pos = 0;
    io._give_back_buffer(held);
    true
}

// Tells the destination that this direction ended, unless the other direction has already ended too: then the link closes right away
// and the close itself sends the FIN (one system call less per connection).
fn _shutdown_unless_closing(s: _Link&, up: bool, dst: i32) {
    let other .= s._direction_of(!up);
    if other.eof && other.shut { return; }
    c_shutdown_wr(dst);
}

// The forwarding arm of the loop's dispatch: the event only says what the sockets can do now.
fn _dispatch_forward(io: Loop&, slot: i64, kind: u64, events: u32) {
    let s .= io._links[slot];
    let from_client = kind == _EVENT_KIND_LINK;
    let in_flag = if from_client { _READY_CLIENT_IN } else { _READY_SERVER_IN };
    let out_flag = if from_client { _READY_CLIENT_OUT } else { _READY_SERVER_OUT };
    let ended_flag = if from_client { _READY_CLIENT_ENDED } else { _READY_SERVER_ENDED };
    if (events & (c_EPOLLIN | c_EPOLLHUP | c_EPOLLRDHUP)) != 0 { s.ready |= in_flag; }
    if (events & (c_EPOLLOUT | c_EPOLLHUP)) != 0 { s.ready |= out_flag; }       // a hung-up socket "can write": the write fails and says so
    if (events & (c_EPOLLRDHUP | c_EPOLLHUP)) != 0 { s.ready |= ended_flag; }
    if s.state == _CONNECTING {
        // A client that hangs up while we connect is only noted (its flags): the connect finishes or fails first.
        if !from_client { io._connect_finished(slot); }
        return;
    }
    if (events & c_EPOLLERR) != 0 {
        if from_client { io._end_forward(slot, goose_io::CloseReason.PeerReset); return; }
        // The backend reset the connection. Bytes it sent before the RST are still readable (Linux), and "answer, then reset" is what a server does
        // when it closes with unread request bytes: deliver them first. The next read says ECONNRESET and closes.
        s.ready |= in_flag | out_flag;
        io._pump(slot);
        if s.state == _FORWARDING && !s.queued && s.up.len <= s.up.pos && s.down.len <= s.down.pos { io._end_forward(slot, goose_io::CloseReason.PeerReset); }
        return;
    }
    io._pump(slot);
}

// The idle, half-close and connect limits of a forwarded link (called from the sweep).
fn _sweep_forward(io: Loop&, i: i64, now: i64) {
    let s .= io._links[i];
    let limits = io.limits;
    if s.state == _CONNECTING {
        if s.server_fd >= 0 && now - s.started_ms >= limits.connect_timeout_ms { io._stats.connect_failures++; io._end_forward(i, goose_io::CloseReason.ConnectFailed { kind: goose_io::ConnectFailure.TimedOut }); }
    } else if s.half_closed_at_ms != 0 {
        let since = if s.last_active_ms > s.half_closed_at_ms { s.last_active_ms } else { s.half_closed_at_ms };
        if now - since >= limits.half_close_timeout_ms { io._end_forward(i, goose_io::CloseReason.HalfCloseTimeout); }
    } else if now - s.last_active_ms >= limits.idle_timeout_ms {
        io._end_forward(i, goose_io::CloseReason.IdleTimeout);
    }
}
