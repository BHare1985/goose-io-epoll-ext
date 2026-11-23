#!/usr/bin/env bash
# The seam proof of the epoll event loop: goose-io-epoll-ext (the loop with tcprouter's forward pump added back, a fixed target) against
# tcprouter's forward_server, system calls per request and throughput on 11 B, 16 KiB and 64 KiB keep-alive workloads. Idle host.
set -eu
EPOLL_DIR="$(cd "$(dirname "$0")/.." && pwd)"; EPOLL_EXT_DIR="$EPOLL_DIR"  # this repository
cd "$(dirname "$0")/.."
[ -x bench/baseline/forward_server ] && [ -x bench/baseline/backend ] || { echo "bench/baseline/forward_server and backend are missing: see bench/BASELINE.md"; exit 2; }
cand="${TMPDIR:-/tmp}/epoll-forward_server"
goose build "$EPOLL_EXT_DIR/forward_server.goose" -o "$cand" >/dev/null
mkdir -p bench/results
stamp="$(date +%Y%m%d-%H%M%S)"; out="bench/results/forward-$stamp.txt"
{ echo "# $(date -u +%FT%TZ)  host: $(uname -r), $(lscpu | sed -n 's/^Model name: *//p'), $(nproc) threads; $(uptime)"
  echo "# baseline: tcprouter $(cat bench/baseline/COMMIT 2>/dev/null || echo '?') forward_server; candidate: goose-io $(git rev-parse --short HEAD) goose-io-epoll-ext"
  python3 bench/gate_forward.py bench/baseline/forward_server "$cand" "$@"; } | tee "$out"
echo "stored: $out"
