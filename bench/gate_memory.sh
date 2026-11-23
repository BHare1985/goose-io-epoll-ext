#!/usr/bin/env bash
# The memory gate of the epoll event loop: RSS idle, with 10,000 idle links and under load, against tcprouter's http_hello.
set -eu
EPOLL_DIR="$(cd "$(dirname "$0")/.." && pwd)"; EPOLL_EXT_DIR="$EPOLL_DIR"  # this repository
cd "$(dirname "$0")/.."
cand="${TMPDIR:-/tmp}/epoll-candidate-http_hello"
"$EPOLL_DIR/build.sh" "$EPOLL_DIR/http_hello.goose" "$cand" >/dev/null
idle="${TMPDIR:-/tmp}/epoll-candidate-idle_server"
"$EPOLL_DIR/build.sh" "$EPOLL_DIR/tests/idle_server.goose" "$idle" >/dev/null
mkdir -p bench/results
stamp="$(date +%Y%m%d-%H%M%S)"; out="bench/results/memory-$stamp.txt"
{ echo "# $(date -u +%FT%TZ)  host: $(uname -r); baseline: tcprouter $(cat bench/baseline/COMMIT 2>/dev/null || echo '?'); candidate: goose-io $(git rev-parse --short HEAD)"
  python3 bench/memory.py bench/baseline/http_hello "$cand" --idle-baseline bench/baseline/idle_server --idle-candidate "$idle" "$@"; } | tee "$out"
echo "stored: $out"
