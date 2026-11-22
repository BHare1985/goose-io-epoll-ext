#!/usr/bin/env bash
# Runs the conformance suite against the epoll event loop, on real sockets: every part of the core and of each group the loop
# supplies (half-close, sizing, abort, inspection and batching; the unix group is not supplied), one process for each part.
# Usage: conformance.sh [--repeat N] [--group G]
# A part that fails in any repetition fails the run. Unlike the in-memory event loop the real one is not deterministic, so the
# output of repetitions is not compared: a failure in any of them is a failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; goose_io="${GOOSE_IO:-${GOOSE_HOME:-$HOME/.goose}/pkg/github.com/BHare1985/goose-io/v0.3}"; cd "$here"
repeat=1; only=
while [ $# -gt 0 ]; do
    case "$1" in
        --repeat) shift; repeat="${1:?--repeat needs a number}" ;;
        --group) shift; only="${1:?--group needs a name}" ;;
        *) echo "unknown argument $1"; exit 2 ;;
    esac
    shift
done
tmp=$(mktemp -d "${TMPDIR:-/tmp}/epoll-conformance.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
./build.sh conformance.goose "$tmp/conformance" >"$tmp/build.log" 2>&1 || { cat "$tmp/build.log"; echo "BUILD FAILED"; exit 1; }
tsv="$goose_io/tests/conformance/checks.tsv"
groups=$(grep -v '^#' "$tsv" | cut -f6 | sort -u | grep -v '^unix$')
[ -n "$only" ] && groups="$only"
failed=0; total=0
for g in $groups; do
    parts=$(grep -v '^#' "$tsv" | awk -F'\t' -v g="$g" '$6 == g {print $2}' | sort -un)
    for ((i = 1; i <= repeat; i++)); do
        for p in $parts; do
            total=$((total + 1))
            if ! "$tmp/conformance" "$p" "$g" >"$tmp/out" 2>&1; then
                echo "FAIL  $g part $p, repetition $i"; sed 's/^/      /' "$tmp/out"; failed=$((failed + 1))
            elif [ $i -eq 1 ]; then
                echo "ok    $g part $p: $(tail -n 1 "$tmp/out")"
            fi
        done
    done
done
echo "$total part runs ($repeat repetitions), $failed failed"
[ $failed -eq 0 ]
