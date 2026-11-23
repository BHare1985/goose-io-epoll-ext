// Proves: RT-2b RT-2c at unit level   (moved here from tcprouter's tests/unit/generation_test.goose, which tested its own engine)
//
//     ./build.sh unit/generation_test.goose /tmp/gen && /tmp/gen
//
// RT-2c: the kernel never sends an out-of-range slot, so the check is tested by handing the dispatcher events it would not get.
// RT-2b: an event with an old generation never touches the link now in that slot. The test reaches the loop's internal names
// (_dispatch_event, _pack_event_data, the counters in stats()) on purpose; it is the one test allowed to.
// net/tc/generation_test.py proves the same row over a million real sockets.
import goose_io from "github.com/BHare1985/goose-io@v0.3";
import epoll_ext from "..";

var checks: i64 = 0;
var failures: i64 = 0;
var phase: i64 = 0;
var closed: i64 = 0;

fn check(ok: bool, what: const u8[:]) {
    checks++;
    if !ok { failures++; print("FAIL: ", what); }
}

fn forge(io: epoll_ext::Loop&) {
    let LINK = epoll_ext::_EVENT_KIND_LINK;
    let SERVER = epoll_ext::_EVENT_KIND_SERVER;
    let IN = epoll_ext::c_EPOLLIN;
    let OUT = epoll_ext::c_EPOLLOUT;
    var s = io.stats();
    check(s.accepted == 0 && s.open == 0 && closed == 1 && s.connect_failures == 1, "the dial to a port with no listener failed and its link is gone");
    check(s.bad_events == 0, "no bad events from a real link");
    let stale0 = s.stale_events;

    // RT-2b: events for a link that is gone (slot 0 was generation 1; closing bumped it).
    io._dispatch_event(epoll_ext::_pack_event_data(LINK, 0, 1), IN);
    s = io.stats();
    check(s.stale_events == stale0 + 1, "an event with the old generation is counted as stale");
    io._dispatch_event(epoll_ext::_pack_event_data(SERVER, 0, 2), IN | OUT);
    s = io.stats();
    check(s.stale_events == stale0 + 2, "an event for a free slot, even at the current generation, is stale");

    // RT-2c: slot indices the table does not have.
    let bad0 = s.bad_events;
    io._dispatch_event(epoll_ext::_pack_event_data(LINK, 7, 1), IN);
    io._dispatch_event(epoll_ext::_pack_event_data(SERVER, 1073741824, 1), IN);
    io._dispatch_event(epoll_ext::_pack_event_data(LINK, 4294967295, 1), IN | OUT);
    s = io.stats();
    check(s.bad_events == bad0 + 3, "slot numbers past the table are counted as bad, not used");

    // Event kinds that do not exist, and a listener index that does not exist, are bad too.
    io._dispatch_event(epoll_ext::_pack_event_data(9, 0, 2), IN);
    io._dispatch_event(epoll_ext::_pack_event_data(0, 0, 2), IN);
    io._dispatch_event(epoll_ext::_pack_event_data(epoll_ext::_EVENT_KIND_LISTENER, 5, 0), IN);
    s = io.stats();
    check(s.bad_events == bad0 + 6, "unknown kinds and a listener index past the table are counted as bad");
    check(s.open == 0 && s.buffers_in_use == 0, "none of that changed anything else");

    // RT-2b at unit level: the next dial reuses slot 0. An event of the old generation must not end or change it.
    let l = io.dial("127.0.0.1:1", 1000);
    s = io.stats();
    check(s.open == 1 && l.slot == 0 && l.gen > 1, "a second link uses the freed slot with a newer generation");
    io._dispatch_event(epoll_ext::_pack_event_data(LINK, 0, 1), epoll_ext::c_EPOLLERR);
    io._dispatch_event(epoll_ext::_pack_event_data(SERVER, 0, 1), epoll_ext::c_EPOLLHUP);
    s = io.stats();
    check(s.open == 1 && s.stale_events == stale0 + 4, "events of the old generation did not touch the new link");
    phase = 2;
}

fn on_event(io: epoll_ext::Loop&, ev: goose_io::Event) {
    match ev {
        Closed c => {
            closed++;
            if phase == 2 { check(true, "the new link ended through its own events"); io.stop(0); }
        },
        Tick t => { if phase == 0 { phase = 1; forge(io); } else { io.tick_by(t.now_ms + 50); } },
        _ => {},
    }
}

fn main() {
    var io = epoll_ext::Loop { .. };
    io.dial("127.0.0.1:1", 1000);
    io.tick_by(io.now_ms() + 300);
    io.serve() { io, ev => on_event(io, ev); };
    if failures > 0 { print(failures, " of ", checks, " checks FAILED"); exit(1); }
    print("all ", checks, " checks passed");
}
