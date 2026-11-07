# Hello

A minimal HTTP server with one route: `GET /` returns `Hello, Roc!`.

From the repository root, with the [pinned toolchain](../../docs/toolchain.md):

```sh
zig build host
roc build --output=hello examples/hello/app.roc
./hello
```

The server prints its assigned port. In another terminal, run `curl http://127.0.0.1:<port>/`. Stop the server with Ctrl-C.

`init!` supplies an empty model and listener settings. `Handler.static` serves a fixed reply without request extraction or external dependencies. See [getting started](../../docs/guides/getting-started.md) for the application contract and [DDD](../ddd/README.md) for a larger application.
