# The baseline the epoll event loop is measured against

The loop under goose-io-epoll is made from tcprouter's engine, so tcprouter's engine is what it is measured against: the
same program, on both, doing the same task.

| | |
|---|---|
| Baseline | tcprouter `e021769` (`main`, v0.6.1), read from `~/dev/cnamecloud/tcprouter` and built from `git archive HEAD` of that commit, so from a clean tree |
| Programs | `examples/http_hello.goose` and `tests/net/harness/forward_server.goose` of that commit, built with `goose build` at the default `-O2` into `bench/baseline/` (git-ignored: the repository of tcprouter is private) |
| Goose | v2026.4 (runtime `dce889723a23`) |
| Host | AMD Ryzen 5 3550H (4 cores, 8 threads), Linux 7.0.0-42-generic |

**This is not the commit the change was planned against.** The change (`proposal.md`, `design.md`) names `05995d1`, from which
`main` differed only in documents. tcprouter has moved on since: `e021769` adds the early-close retry of a server that ends before
its first byte on an inspecting listener (`RT-21`, `conn.goose`: `_send_hello`, `_commit_hello`, `_early_end`). That is proxy code,
which the loop does not carry, and the handler path (`handler.goose`) and the generic layer are as they were, so `http_hello` is
the same program on either commit. The owner asked for the current commit.

Build the baseline again:

```bash
git -C ~/dev/cnamecloud/tcprouter archive HEAD | tar -x -C "$(mktemp -d)"     # then, in that directory:
goose build examples/http_hello.goose -o bench/baseline/http_hello
goose build tests/net/harness/forward_server.goose -o bench/baseline/forward_server
```

`bench/baseline/COMMIT` holds the commit the binaries were built from. The gates are `bench/gate_syscalls.sh` and `bench/gate_http.sh`
(see `bench/README.md`); their results are stored under `bench/results/` with the host, both commits and the date.
