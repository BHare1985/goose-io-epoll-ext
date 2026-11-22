#!/usr/bin/env bash
# Builds the programs the network tests drive and runs every tests/net/*_test.py against them, on real sockets.
# Usage: net/run.sh [filter]       REPEAT=20 net/run.sh lineserver
# A filter selects the drivers whose file name contains it. REPEAT=n runs each driver n times and keeps every FAIL line (a test
# that failed once in any repetition is a failure until its cause is explained). Exit status is non-zero on any failure.
set -u
cd "$(dirname "$0")/.."
filter="${1:-}"; repeat="${REPEAT:-1}"
bin="$(mktemp -d "${TMPDIR:-/tmp}/epoll-net.XXXXXX")"; trap 'rm -rf "$bin"' EXIT
export NET_BIN="$bin"
${CC:-cc} -O1 -o "$bin/c_echo_server" net/tc/echo_server.c && export ECHO_SERVER="$bin/c_echo_server" FORWARD_SERVER="$bin/forward_server"
failed=0; ran=0
for src in tests/*.goose http_hello.goose forward_server.goose; do
    [ -e "$src" ] || continue
    name="$(basename "$src" .goose)"
    # a program is built only when some selected driver needs it (its name appears in the driver)
    needed=0
    for d in net/*_test.py net/tc/*_test.py; do case "$d" in *"$filter"*) grep -q "\"$name\"" "$d" && needed=1; case "$d" in net/tc/*) [ "$name" = forward_server ] && needed=1 ;; esac ;; esac; done
    [ $needed -eq 1 ] || continue
    if ! ./build.sh "$src" "$bin/$name" >"$bin/$name.log" 2>&1; then
        echo "BUILD FAILED  $src"; sed 's/^/    /' "$bin/$name.log" | head -20; failed=$((failed + 1))
    fi
done
for d in net/*_test.py net/tc/*_test.py; do
    [ -e "$d" ] || continue
    case "$d" in *"$filter"*) ;; *) continue ;; esac
    ran=$((ran + 1))
    bad=0
    for ((i = 1; i <= repeat; i++)); do
        if ! python3 "$d" >"$bin/out" 2>&1; then
            bad=$((bad + 1)); grep -E '^(FAIL|Traceback|  File|[A-Za-z]*Error)' "$bin/out" | head -8 | sed "s|^|    [$i] |"
        fi
    done
    if [ $bad -eq 0 ]; then echo "PASS  $(basename "$d")   $(tail -1 "$bin/out")   x$repeat"; else echo "FAIL  $(basename "$d")   $bad of $repeat repetitions failed"; failed=$((failed + 1)); fi
done
if [ -z "$filter" ] || case "unit" in *"$filter"*) true ;; *) false ;; esac; then
    if ./build.sh unit/generation_test.goose "$bin/generation_unit" >"$bin/gu.log" 2>&1 && "$bin/generation_unit" >"$bin/gu.out" 2>&1; then
        ran=$((ran + 1)); echo "PASS  unit/generation_test.goose   $(tail -1 "$bin/gu.out")"
    else ran=$((ran + 1)); failed=$((failed + 1)); echo "FAIL  unit/generation_test.goose"; tail -5 "$bin/gu.log" "$bin/gu.out"; fi
fi
echo "$ran network tests, $failed failed"
[ $failed -eq 0 ]
