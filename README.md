# goose-io-epoll-ext

[goose-io-epoll](https://github.com/BHare1985/goose-io-epoll) plus what a performant TCP proxy needs: the forwarding pump (`forward.goose`),
where the loop moves a forwarded connection's bytes to its target and back itself. This repository is that loop's code with one commit
on top of goose-io-epoll's; `git diff <first commit> HEAD` is the extension (namespace `epoll_ext`).

`forward_server.goose` is the proof: a server forwarding every connection of its listener to one target.

```bash
./build.sh forward_server.goose forward_server
./conformance.sh --repeat 3     # the goose-io conformance suite, which the extension must still pass
```

Fetches goose-io v0.2 with `goose fetch`; needs Goose v2026.4 and a C compiler.

`forward.goose` is derived from the private tcprouter repository.
