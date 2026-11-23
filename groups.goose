// The proxy groups of contract 0.3 on the epoll loop: relay, peek, revoke, wake and limits (the first three move bytes
// between links or hold them, wake crosses threads, limits time the links). Everything here is built from the engine's own parts: the
// pool buffers, the pending queue and the per-pass scan; nothing is a new mechanism in epoll.
//
// Relay. A relayed link reads into its own pool buffer (`rbuf`, `rlen`, `rpos`) and writes that buffer to its partner; it reads again
// only when the buffer is empty, so a partner that does not drain holds the reader back (the kernel's buffers do the rest). epoll is
// level-triggered, so a pump that stops early is simply called again by the next epoll_wait.
// Peek. Held bytes live in the same buffer as Data's: `wait_input` withholds the Data record and reads up to the bound into it.
namespace epoll_ext;

import std;
import goose_io;
import .sys;
import .config;
import .engine;

let _FOREVER: i64 = 0x7fffffffffffffff;

fn _failure(err: i64) -> goose_io::CloseReason {
    if err == c_ECONNRESET as i64 || err == c_EPIPE as i64 { return goose_io::CloseReason.PeerReset; }
    goose_io::CloseReason.Error
}

fn _limit_of(v: i64) -> goose_io::Limit {
    if v == 0 { return goose_io::Limit.Idle; }
    if v == 1 { return goose_io::Limit.Silent; }
    if v == 2 { return goose_io::Limit.Stalled; }
    if v == 3 { return goose_io::Limit.HalfOpen; }
    goose_io::Limit.Age
}

fn _limit_index(l: goose_io::Limit) -> i64 {
    if l == goose_io::Limit.Idle { return 0; }
    if l == goose_io::Limit.Silent { return 1; }
    if l == goose_io::Limit.Stalled { return 2; }
    if l == goose_io::Limit.HalfOpen { return 3; }
    4
}

// --- relay ---------------------------------------------------------------------------------------

// Buffers one direction of a relay reads per wakeup before others get a turn (about forward.goose's _WAKEUP_BUDGET with the default buffer size).
let _RELAY_ROUNDS: i64 = 2;

// The partner of a relayed link has bytes read and not yet written to it.
fn _relay_pending_for(io: Loop&, i: i64) -> bool {
    let s .= io._links[i];
    if !s.relayed { return false; }
    let p .= io._links[s.partner];
    p.rbuf >= 0 && p.rpos < p.rlen
}

fn relay(io: Loop&, first: goose_io::Link, second: goose_io::Link) -> goose_io::RelayStatus {
    if io._finished { return goose_io::RelayStatus.Closed; }
    let a = io._find(first);
    let b = io._find(second);
    if a < 0 || b < 0 || a == b { return goose_io::RelayStatus.Closed; }
    let sa .= io._links[a];
    let sb .= io._links[b];
    if sa.state == _ENDED || sb.state == _ENDED || sa.closing || sb.closing { return goose_io::RelayStatus.Closed; }
    if sa.state != _OPEN || sb.state != _OPEN { return goose_io::RelayStatus.NotOpen; }
    if sa.relayed || sb.relayed { return goose_io::RelayStatus.AlreadyRelayed; }
    if sa.wr_shut || sb.wr_shut || sa.shut_wr_pending || sb.shut_wr_pending { return goose_io::RelayStatus.Closed; }
    if io._same_connection(a, b) { return goose_io::RelayStatus.Closed; }
    io._take_over(a);
    io._take_over(b);
    sa.relayed = true;
    sb.relayed = true;
    sa.partner = b;
    sb.partner = a;
    io._relay_pump(a);
    io._relay_pump(b);
    goose_io::RelayStatus.Started
}

// True when the two links are the two ends of one connection (a relay would feed a link's bytes into itself).
fn _same_connection(io: Loop&, a: i64, b: i64) -> bool {
    let sa .= io._links[a];
    let sb .= io._links[b];
    if sa.fd < 0 || sb.fd < 0 { return false; }
    var pa: u8[18] = [0; 18];
    var pb: u8[18] = [0; 18];
    let fa = c_peer(sa.fd, pa);
    let fb = c_peer(sb.fd, pb);
    if fa <= 0 || fb <= 0 || fa != fb { return false; }
    let la = c_local_port(sa.fd);
    let lb = c_local_port(sb.fd);
    if la < 0 || lb < 0 { return false; }
    let pa_port = ((pa[16] as i64) << 8) | (pa[17] as i64);
    let pb_port = ((pb[16] as i64) << 8) | (pb[17] as i64);
    pa_port == lb && pb_port == la
}

// A link about to be relayed gives up its withholding and hands the bytes it holds (not yet delivered) to the relay.
fn _take_over(io: Loop&, i: i64) {
    let s .= io._links[i];
    s.paused = false;
    s.wait_n = 0;
    io._hold_end(i);
    s.input_sent = false;
    s.rpos = 0;
    if s.data_pending && s.rbuf >= 0 {
        if s.delivering { s.rpos = s.rlen; }             // the application has these bytes: the relay starts after them
        s.data_pending = false;
        s.data_queued = false;
    }
    s.eof_held = false;
}

fn relayed_bytes(io: Loop&, link: goose_io::Link) -> i64 {
    let i = io._find(link);
    if i < 0 { return 0; }
    io._links[i].carried
}

// The relay ends: both links are ordinary again, and the bytes held for the relay are given up.
fn _unrelay(io: Loop&, i: i64) {
    let s .= io._links[i];
    s.relayed = false;
    s.partner = -1;
    if !s.delivering && s.rbuf >= 0 {
        let b = s.rbuf;
        s.rbuf = -1;
        s.rlen = 0;
        io._give_back_buffer(b);
    }
    s.rpos = 0;
}

// A relayed link ends: the pair ends as one. The failing link carries the true cause; its partner is told Error after a failure
// (and reset), and Local after a limit of the loop's own.
fn _end_pair(io: Loop&, i: i64, reason: goose_io::CloseReason) {
    let s .= io._links[i];
    let pi = s.partner;
    var partner_why = goose_io::CloseReason.Error;
    var hard = false;
    match reason {
        PeerClosed => { partner_why = goose_io::CloseReason.PeerClosed; },
        Local => { partner_why = goose_io::CloseReason.Local; },
        Shutdown => { partner_why = goose_io::CloseReason.Shutdown; },
        IdleTimeout => { partner_why = goose_io::CloseReason.Local; },
        HalfCloseTimeout => { partner_why = goose_io::CloseReason.Local; },
        _ => { hard = true; },
    }
    io._unrelay(i);
    if pi >= 0 { io._unrelay(pi); }
    io._end_one(i, reason);
    if pi >= 0 {
        if hard && io._links[pi].fd >= 0 { c_linger0(io._links[pi].fd); }
        io._skip_drain_count = true;
        io._end_one(pi, partner_why);
        io._skip_drain_count = false;
    }
}

// close or reset of a relayed link: the library closes the pair.
fn _close_pair(io: Loop&, i: i64, hard: bool) {
    let pi = io._links[i].partner;
    io._unrelay(i);
    io._unrelay(pi);
    for k in 2 {
        let x = if k == 0 { i } else { pi };
        let s .= io._links[x];
        s.local_closed = true;
        if hard {
            if s.fd >= 0 { c_linger0(s.fd); }
            s.closing = true;
            s.closing_reason = goose_io::CloseReason.Local;
            io._end(x, goose_io::CloseReason.Local);
        } else {
            io._begin_close(x, goose_io::CloseReason.Local);
        }
    }
}

// The end of link i's stream reaches its partner. False when the pair ended.
fn _relay_eof(io: Loop&, i: i64) -> bool {
    let s .= io._links[i];
    if s.relay_eof_passed { return true; }
    let pi = s.partner;
    let p .= io._links[pi];
    if p.out_count > 0 { return true; }                 // the library's queue goes first
    c_shutdown_wr(p.fd);
    p.wr_shut = true;
    s.relay_eof_passed = true;
    s.peer_end_ms = io._now_ms;
    if p.half_closed_at_ms == 0 { p.half_closed_at_ms = io._now_ms; }
    if io._limits_used { io._limit_next = 0; }
    if p.relay_eof_passed {
        io._unrelay(i);
        io._unrelay(pi);
        io._end_one(i, goose_io::CloseReason.PeerClosed);
        io._end_one(pi, goose_io::CloseReason.PeerClosed);
        return false;
    }
    true
}

// Moves bytes from link i to its partner until one of them cannot go on.
fn _relay_pump(io: Loop&, i: i64) {
    let s .= io._links[i];
    if !s.relayed || s.state != _OPEN || s.delivering { return; }
    let pi = s.partner;
    let p .= io._links[pi];
    var rounds = 0;
    var progress = false;
    var drained = false;          // a short read emptied the socket: level-triggered, so the next byte wakes us; no recv to learn EAGAIN
    loop {
        if s.rbuf >= 0 {
            if s.rpos < s.rlen {
                if p.out_count > 0 { break; }
                if io._deadline_passed(pi) { return; }
                let rest = io._buffer_slice(s.rbuf)[s.rpos..s.rlen];
                let n = c_send(p.fd, rest[0], rest.len);
                if n > 0 {
                    s.rpos += n as i32;
                    s.carried += n;
                    progress = true;
                    s.last_active_ms = io._now_ms;
                    p.last_active_ms = io._now_ms;
                    io._stats.bytes_out += n;
                    continue;
                }
                if n == -(c_EINTR as i64) { continue; }
                if n == -(c_EAGAIN as i64) { break; }
                io._end(pi, _failure(-n));
                return;
            }
            let b = s.rbuf;
            s.rbuf = -1;
            s.rlen = 0;
            s.rpos = 0;
            io._give_back_buffer(b);
        }
        if s.eof_seen {
            if !io._relay_eof(i) { return; }
            break;
        }
        if !s._wants_read() || rounds >= _RELAY_ROUNDS || drained { break; }
        rounds++;
        let b = io._take_buffer();
        if b < 0 {
            s.waiting = true;
            io._waiting_reads.push(_pack_event_data(_WAITER_READER, i, s.gen));
            io._stats.buffer_waits++;
            break;
        }
        let buffer = io._buffer_slice(b);
        let n = c_recv(s.fd, buffer[0], buffer.len);
        if n > 0 {
            s.rbuf = b;
            s.rlen = n as i32;
            s.rpos = 0;
            if n < buffer.len { drained = true; }
            s.last_active_ms = io._now_ms;
            p.last_active_ms = io._now_ms;
            s.last_read_ms = io._now_ms;
            io._stats.bytes_in += n;
            continue;
        }
        io._give_back_buffer(b);
        if n == 0 {
            s.eof_seen = true;
            s.peer_end_ms = io._now_ms;
            continue;
        }
        if n == -(c_EINTR as i64) { continue; }
        if n == -(c_EAGAIN as i64) { break; }
        io._end(i, _failure(-n));
        return;
    }
    io._stall_update(pi, progress);
    io._stall_update(i, false);
    io._update_interest(i);
    io._update_interest(pi);
}

// --- peek ----------------------------------------------------------------------------------------

fn _peek_bound(io: Loop&) -> i64 {
    var b = io.limits.peek_bound;
    if b < 1 { b = 1; }
    if b > io.limits.buffer_size { b = io.limits.buffer_size; }
    if b > io._scratch.len { b = io._scratch.len; }
    b
}

// Queues the Input when the held bytes are enough, the peer has ended, or the bound is reached; once per wait_input.
fn _input_check(io: Loop&, i: i64) {
    let s .= io._links[i];
    if s.wait_n <= 0 || s.input_sent || s.state != _OPEN || s.relayed || s.paused || s.closing || s.delivering { return; }
    var need = s.wait_n;
    let bound = io._peek_bound();
    if need > bound { need = bound; }
    if s.khold >= need || s.eof_held {
        s.input_sent = true;
        io._queue(_PENDING_INPUT, i);
        io._update_interest(i);
    }
}

// Held bytes stay in the kernel (a link that waits for a hello costs the loop no buffer): they are counted with MSG_PEEK, and SO_RCVLOWAT keeps
// epoll quiet until enough have arrived. `woken` is true when epoll said the socket is readable: then a look that finds nothing new means the
// peer ended.
fn _hold_look(io: Loop&, i: i64, woken: bool) {
    let s .= io._links[i];
    if s.state != _OPEN || s.relayed || s.closing || s.paused || s.wait_n <= 0 || s.eof_held { return; }
    let bound = io._peek_bound();
    let n = c_peek(s.fd, io._scratch[0], bound);
    if n > 0 {
        if n > s.khold { s.last_active_ms = io._now_ms; s.last_read_ms = io._now_ms; }
        else if woken { s.eof_held = true; }
        s.khold = n;
    } else if n == 0 {
        s.eof_held = true;
    } else if n == -(c_EAGAIN as i64) || n == -(c_EINTR as i64) {
        // nothing yet
    } else {
        io._end(i, goose_io::CloseReason.PeerReset);
        return;
    }
    io._input_check(i);
    io._update_interest(i);
}

fn _hold_read(io: Loop&, i: i64) { io._hold_look(i, true); }

// Back to ordinary reading: the low-water mark returns to 1.
fn _hold_end(io: Loop&, i: i64) {
    let s .= io._links[i];
    if s.lowat_raised && s.fd >= 0 { c_set_rcvlowat(s.fd, 1); s.lowat_raised = false; }
    s.khold = 0;
}

// wait_input(0) or the end of a pause: what is held is handed over as Data, then the end of stream.
fn _release_held(io: Loop&, i: i64) {
    let s .= io._links[i];
    if s.state != _OPEN || s.wait_n > 0 || s.paused || s.relayed { return; }
    io._hold_end(i);
    s.eof_held = false;
    s.input_sent = false;
    if !s.data_pending { io._read_link(i); if s.state != _OPEN { return; } }
    if s.data_pending && !s.data_queued && s.rbuf >= 0 && !s.delivering {
        s.data_queued = true;
        io._queue(_PENDING_DATA, i);
    }
    if s.eof_held {
        s.eof_held = false;
        io._queue(_PENDING_EOF, i);
    }
}

fn wait_input(io: Loop&, link: goose_io::Link, byte_count: i64) {
    if io._finished { return; }
    let i = io._find(link);
    if i < 0 { return; }
    let s .= io._links[i];
    if s.state != _OPEN || s.relayed { return; }
    s.wait_n = if byte_count > 0 { byte_count } else { 0 };
    s.input_sent = false;
    if s.wait_n == 0 {
        io._release_held(i);
    } else {
        var low = s.wait_n;
        let bound = io._peek_bound();
        if low > bound { low = bound; }
        if low > 1 && s.fd >= 0 { c_set_rcvlowat(s.fd, low as i32); s.lowat_raised = true; }
        else if s.lowat_raised && s.fd >= 0 { c_set_rcvlowat(s.fd, 1); s.lowat_raised = false; }
        io._hold_look(i, false);
    }
    io._update_interest(i);
}

fn peek(io: Loop&, link: goose_io::Link) -> const u8[:] {
    if io._finished { return ""; }
    let i = io._find(link);
    if i < 0 { return ""; }
    let s .= io._links[i];
    if s.state == _OPEN && !s.relayed && s.wait_n > 0 && !s.delivering {
        let got = c_peek(s.fd, io._scratch[0], io._peek_bound());
        if got <= 0 { return ""; }
        return io._scratch[..got];
    }
    if s.state != _OPEN || s.relayed || !s.data_pending || s.rbuf < 0 || s.delivering { return ""; }
    var n = s.rlen as i64;
    let bound = io._peek_bound();
    if n > bound { n = bound; }
    io._buffer_slice(s.rbuf)[..n]
}

// Drops the first byte_count held bytes (at most what peek shows) of an open link that is not relayed; no Input, no Data.
fn discard_input(io: Loop&, link: goose_io::Link, byte_count: i64) -> i64 {
    if io._finished { return 0; }
    let i = io._find(link);
    if i < 0 { return 0; }
    let s .= io._links[i];
    if s.state == _OPEN && !s.relayed && s.wait_n > 0 && !s.delivering {
        var left = byte_count;
        if left > s.khold { left = s.khold; }
        var dropped: i64 = 0;
        while left > 0 {
            let take = if left < io._scratch.len { left } else { io._scratch.len };
            let got = c_recv(s.fd, io._scratch[0], take);
            if got <= 0 { break; }
            dropped += got;
            left -= got;
        }
        s.khold -= dropped;
        io._stats.bytes_in += dropped;
        return dropped;
    }
    if s.state != _OPEN || s.relayed || !s.data_pending || s.rbuf < 0 || s.delivering { return 0; }
    var n = s.rlen as i64;
    let bound = io._peek_bound();
    if n > bound { n = bound; }
    if byte_count < n { n = byte_count; }
    if n <= 0 { return 0; }
    let buffer = io._buffer_slice(s.rbuf);
    let rest = s.rlen as i64 - n;
    if rest > 0 {
        buffer[..rest].move_from(buffer[n..n + rest]);
        s.rlen = rest as i32;
    } else {
        let b = s.rbuf;
        s.rbuf = -1;
        s.rlen = 0;
        s.data_pending = false;
        io._give_back_buffer(b);
    }
    io._update_interest(i);
    n
}

// --- revoke --------------------------------------------------------------------------------------

fn discard_unsent(io: Loop&, link: goose_io::Link) -> i64 {
    if io._finished { return 0; }
    let i = io._find(link);
    if i < 0 { return 0; }
    let s .= io._links[i];
    if s.state != _OPEN || s.relayed { return 0; }
    var count: i64 = 0;
    let n = s.out_count as i64;
    var ids: i32[4] = [-1; 4];
    for k in n {
        count += s.out_lengths[k] as i64;
        ids[k] = s.out_buffers[k];
    }
    count -= s.out_pos as i64;
    s.out_count = 0;
    s.out_pos = 0;
    for k in n { io._give_back_buffer(ids[k]); }
    io._flush_output(i);
    count
}

fn write_deadline(io: Loop&, link: goose_io::Link, at_ms: i64) {
    if io._finished { return; }
    let i = io._find(link);
    if i < 0 { return; }
    let s .= io._links[i];
    if s.state != _OPEN && s.state != _DIALING { return; }
    s.write_deadline = if at_ms > 0 { at_ms } else { 0 };
    if at_ms > 0 { io._limits_used = true; io._limit_next = 0; }
}

// The deadline of link i has passed (the clock is read now, not taken from the pass): the link ends Local, and True is returned.
fn _deadline_passed(io: Loop&, i: i64) -> bool {
    let s .= io._links[i];
    if s.write_deadline <= 0 || c_boottime_ms() < s.write_deadline { return false; }
    s.write_deadline = 0;
    if s.state != _OPEN { return true; }
    s.local_closed = true;
    if s.fd >= 0 { c_linger0(s.fd); }
    s.closing = true;
    s.closing_reason = goose_io::CloseReason.Local;
    io._end(i, goose_io::CloseReason.Local);
    true
}

// --- limits --------------------------------------------------------------------------------------

// Something waits for the transport on link i (queued bytes, or bytes the relay holds for it): when it began, or -1.
fn _stall_update(io: Loop&, i: i64, progress: bool) {
    let s .= io._links[i];
    if s.state != _OPEN { return; }
    let waiting = s.out_count > 0 || io._relay_pending_for(i);
    if !waiting {
        if s.stall_since >= 0 { s.stall_since = -1; }
    } else if progress || s.stall_since < 0 {
        s.stall_since = io._now_ms;
        if io._limits_used { io._limit_next = 0; }
    }
}

fn set_limit(io: Loop&, link: goose_io::Link, limit: goose_io::Limit, ms: i64) {
    if io._finished { return; }
    let i = io._find(link);
    if i < 0 { return; }
    let s .= io._links[i];
    if s.state != _OPEN && s.state != _DIALING { return; }
    let k = _limit_index(limit);
    s.limit_fired[k] = false;
    if ms <= 0 { s.limit_ms[k] = 0; return; }
    s.limit_ms[k] = ms as i32;
    s.limit_armed[k] = io._now_ms;
    io._limits_used = true;
    io._limit_next = 0;
}

fn _limit_due(s: _Link&, k: i64) -> i64 {
    if s.limit_ms[k] <= 0 || s.limit_fired[k] { return _FOREVER; }
    var from: i64 = 0;
    if k == 0 { from = if s.last_active_ms > s.started_ms { s.last_active_ms } else { s.started_ms }; }
    else if k == 1 { from = if s.last_read_ms > s.started_ms { s.last_read_ms } else { s.started_ms }; }
    else if k == 2 { if s.stall_since < 0 { return _FOREVER; } from = s.stall_since; }
    else if k == 3 { if s.peer_end_ms < 0 { return _FOREVER; } from = if s.last_active_ms > s.peer_end_ms { s.last_active_ms } else { s.peer_end_ms }; }   // whatever crosses since moves it
    else { from = s.started_ms; }
    if s.limit_armed[k] > from { from = s.limit_armed[k]; }
    from + s.limit_ms[k]
}

// Queues an Expired for every limit that has fallen due, ends links whose write deadline passed, and finds the next time to look.
fn _limits_scan(io: Loop&) {
    let now = io._now_ms;
    var next = _FOREVER;
    var any = false;
    for i in io._links.len {
        let s .= io._links[i];
        if s.state != _OPEN { continue; }
        if s.write_deadline > 0 {
            if c_boottime_ms() >= s.write_deadline { io._deadline_passed(i); continue; }
            any = true;
            if s.write_deadline < next { next = s.write_deadline; }
        }
        for k in 5 {
            if s.limit_ms[k] <= 0 { continue; }
            any = true;
            var due = _limit_due(s, k);
            if due == _FOREVER || s.limit_fired[k] { continue; }
            if k == 2 && due <= now {
                // EPOLLOUT is reported only when a good part of the send buffer is free, so a slow reader can be making progress that
                // the loop has not been told of: try the transport before saying it takes nothing.
                if s.out_count > 0 { io._flush_output(i); }
                else if io._relay_pending_for(i) { io._relay_pump(s.partner); }
                if s.state != _OPEN { break; }
                due = _limit_due(s, k);
                if due == _FOREVER { continue; }
            }
            if due <= now {
                s.limit_fired[k] = true;
                io._pending.push(_Pending { kind: _PENDING_EXPIRED, slot: i as u32, gen: s.gen, listener: s.listener, why: goose_io::CloseReason.Local, value: k });
            } else if due < next {
                next = due;
            }
        }
    }
    io._limits_used = any;
    io._limit_next = next;
}

// --- wake ----------------------------------------------------------------------------------------

fn waker(io: Loop&) -> goose_io::Waker {
    if io._finished || !io._ensure() { return goose_io::Waker { .. }; }
    if io._wake_write < 0 {
        var fds: i32[2] = [-1, -1];
        if c_wake_pipe(fds) < 0 { return goose_io::Waker { .. }; }
        if c_epoll_ctl(io._epoll_fd, c_EPOLL_CTL_ADD, fds[0], c_EPOLLIN, _pack_event_data(_EVENT_KIND_WAKE, 0, 0)) < 0 {
            c_close(fds[0]);
            c_close(fds[1]);
            return goose_io::Waker { .. };
        }
        io._wake_read = fds[0];
        io._wake_write = fds[1];
    }
    goose_io::Waker { id: (io._wake_write + 1) as u32, gen: 1 }
}

// From any thread: the value reaches the loop of the waker as one Woken. A full pipe is waited for briefly; the descriptors are
// never closed, so a waker of a loop that has finished writes to a pipe nobody reads, and nothing else.
fn wake(io: Loop&, target: goose_io::Waker, value: i64) {
    io.wake_with(target, value, "");
}

// As wake, with up to 64 bytes (longer text is cut) that arrive in Woken.body. One record of 80 bytes: value, length, body.
// A pipe write of at most PIPE_BUF bytes is atomic, so records from several threads never interleave.
fn wake_with(io: Loop&, target: goose_io::Waker, value: i64, body: const u8[:]) {
    if target.id == 0 { return; }
    var buf: u8[80] = [0; 80];
    let v = value as u64;
    for k in 8 { buf[k] = ((v >> (8 * k)) & 0xff) as u8; }
    let n = if body.len < 64 { body.len } else { 64 };
    buf[8] = n as u8;
    for k in n { buf[16 + k] = body[k]; }
    for attempt in 100 {
        let w = c_pipe_write((target.id - 1) as i32, buf[0], 80);
        if w == 80 { return; }
        if w != -(c_EAGAIN as i64) && w != -(c_EINTR as i64) { return; }
        _pause_milliseconds(1);
    }
}

fn _read_wakes(io: Loop&) {
    var buf: u8[80] = [0; 80];
    for n in 256 {
        let r = c_pipe_read(io._wake_read, buf[0], 80);
        if r != 80 { return; }
        var v: u64 = 0;
        for k in 8 { v |= (buf[k] as u64) << (8 * k); }
        let len = buf[8] as i64;
        let at = io._wake_bodies.len / 64;
        for k in 64 { io._wake_bodies.push(if k < len { buf[16 + k] } else { 0 }); }
        io._pending.push(_Pending { kind: _PENDING_WOKEN, slot: at as u32, gen: len as u32, listener: 0, why: goose_io::CloseReason.Local, value: v as i64 });
    }
}
