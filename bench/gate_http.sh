#!/usr/bin/env bash
# The throughput gate of the epoll event loop: tcprouter's http_hello (bench/baseline/) against goose-io-epoll's http_hello.goose,
# one worker, pinned CPUs, wrk, alternating rounds. Run it on an idle host. Stores the results under bench/results/.
set -eu
EPOLL_DIR="$(cd "$(dirname "$0")/.." && pwd)"; EPOLL_EXT_DIR="$EPOLL_DIR"  # this repository
cd "$(dirname "$0")/.."
[ -x bench/baseline/http_hello ] || { echo "bench/baseline/http_hello is missing: build it as bench/BASELINE.md says"; exit 2; }
cand="${TMPDIR:-/tmp}/epoll-candidate-http_hello"
"$EPOLL_DIR/build.sh" "$EPOLL_DIR/http_hello.goose" "$cand" >/dev/null
mkdir -p bench/results
stamp="$(date +%Y%m%d-%H%M%S)"; out="bench/results/http-$stamp.txt"
{ echo "# $(date -u +%FT%TZ)  host: $(uname -r), $(lscpu | sed -n 's/^Model name: *//p'), $(nproc) threads; $(uptime)"
  echo "# baseline: tcprouter $(cat bench/baseline/COMMIT 2>/dev/null || echo '?'); candidate: goose-io $(git rev-parse --short HEAD)"
  python3 bench/gate_http.py bench/baseline/http_hello "$cand" "$@"; } | tee "$out"
echo "stored: $out"
