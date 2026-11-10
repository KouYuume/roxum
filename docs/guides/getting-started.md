# Getting started

roxum is a web server platform for [Roc](https://www.roc-lang.org). You write the application in Roc: an `init!` that
starts it and a router of handlers. The platform's host, written in Zig, runs the HTTP/1.1 server, its threads,
and the event loops.

## Requirements

- The Roc nightly that roxum is pinned to (see [`docs/toolchain.md`](../toolchain.md)); roxum follows Roc's
  nightly builds closely
- Zig 0.17.1, to build the platform's host from source
- macOS on Apple silicon (`arm64mac`), or Linux on arm64 / x86_64 (`arm64musl` / `x64musl`, statically linked)

## A first app

[`examples/hello/app.roc`](../../examples/hello/app.roc):

```roc
app [program] { pf: platform "../../platform/main.roc" }

import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Router
import pf.IpAddr
import pf.Server

Model := {}

program = {
	init!,
	routes: Router.build(routes, {}),
}

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| Ok({
	model: {},
	listen: {
		address: IpAddr.V4((127, 0, 0, 1)),
		port: 0,
		timeouts: Server.Timeouts.defaults,
		limits: Server.Limits.defaults,
	},
})

routes : Router(Model, [], {})
routes = Router.new
	.route("/", MethodRouter.get(Handler.static(|{}| Reply.text("Hello, Roc!\n"))))
```

- `init!` runs once before the server serves requests. It returns the `Model` your handlers read and
  where to listen. Port `0` picks a free port. `Server.Timeouts.defaults` and `Server.Limits.defaults` keep the
  default timeouts and limits ([Deployment](deployment.md#keep-alive-and-timeouts)). Without `threads`, one
  process serves requests on a thread per CPU ([Deployment](deployment.md#processes-and-threads)).
- `routes` maps paths and methods to handlers. It is an ordinary value, so it is checked and built when the app is
  compiled. Its type is `Router(model, tag, provided)`; an app with no route tags and no values passed from layers to
  handlers writes `Router(Model, [], {})`. `Router.build(routes, {})` closes it for `program`, which names only the
  model.
- `Handler.static` serves a reply that does not depend on the request. Other handlers return `Try(Reply, Reply)`. Both sides are responses; `Err` is for replies that report a failure, and
  middleware can tell them apart.

## Build and run

```bash
zig build host                                   # the platform's host for this machine
roc build --output=hello examples/hello/app.roc
./hello
```

The server prints the port it bound as one line on stdout, then serves:

```bash
curl http://127.0.0.1:<port>/
```

It serves on one thread per logical CPU (up to 256) in a worker process, behind a supervisor that restarts the process
if it stops.
`Ctrl-C` stops them all.

`roc build` uses `--opt=speed` by default, which optimizes with LLVM; `--opt=dev` skips LLVM and builds faster
while you work. Both behave the same.

## Distribution

The instructions above build from source. Release bundles are produced by the repository release tooling; use published bundle URLs only when an actual release is available. See [integration releases](../design/integration-releases.md).

## Handlers

Pick the least capable kind of handler that works; the type then documents what the handler can do.

| Constructor | Signature | Use it for |
|---|---|---|
| `Handler.static` | `{} -> Reply` | responses that do not depend on the request |
| `Handler.pure` | `RouteContext({}) -> Try(Reply, Reply)` | responses computed from the request alone |
| `Handler.stateful` | `Model, RouteContext({}) -> Try(Reply, Reply)` | responses that also read the `Model` |
| `Handler.effectful` | `Model, RouteContext({}) => Try(Reply, Reply)` | handlers that perform effects (logging, time, randomness, running extractors) |
| `Handler.typed` | `Model, { ...fields } => Try(Reply, Reply)` | handlers whose argument's field types say what to read ([Extractors](extractors.md#handlers-with-a-typed-argument)) |
| `Handler.streaming` | `Handler.Streaming.{ begin!, chunk!, done!, abort! }` | request bodies too large to hold ([Streaming](streaming.md#reading-a-large-request-body)) |

All but `Handler.streaming` run after roxum has received the whole body, up to `Server.Limits.maximum_body_bytes`
(2 MiB by default).

A pure function cannot call an effectful one: the compiler rejects it. That keeps effects visible in types and in
names, which end in `!`. [`examples/ddd/`](../../examples/ddd/README.md) shows an application split into layers on
this basis.

## Replies

`Reply.text`, `Reply.json`, `Reply.bytes` (which takes a media type), and `Reply.empty` build a 200 response;
`Reply.with_status` and `Reply.with_headers` adjust it; `Reply.full` takes a complete `Response`, and `Reply.stream`
writes the body as it goes. [Responses](responses.md) has redirects, downloads, and more.

```roc
Reply.text("created\n").with_status(201)
```

## Effects the platform provides

- `Log.info!` and the other levels write one line to stderr
- `Time.now!` reads the wall clock; `Instant.now!` reads a monotonic clock for durations
- `Random.u64!` returns cryptographically secure random bits
- `Config.load!` reads settings from `config/base.toml` and `config/local.toml` into your own type
  ([Deployment](deployment.md#settings))
- `File.read_utf8!` and `File.read_bytes!` read a file up to a size you give, for `init!`
- `Secret.from_file!` and `Secret.from_env!` keep a secret in the host and give Roc a handle; `Secret.derive!` computes
  hashes from it without returning the secret

There is no general environment or process access: the platform only exposes what a web server needs.

## Next

- [Routing](routing.md): paths, parameters, methods, nesting, fallbacks
- [Extractors](extractors.md): typed inputs from the path, query, headers, and body
- [Responses](responses.md): bytes, HTML, redirects, downloads, JSON Lines, links to a route
- [Middleware](middleware.md): layers at the stages of a request, route tags, values for handlers, rate limits
- [Streaming](streaming.md): bodies written as they go, server-sent events, large uploads
- [Files and compression](files.md): serving a directory, compressing responses
- [Databases](database.md): PostgreSQL through `roxum-postgres`, queries into typed records, transactions
- [Calling HTTP APIs](http-client.md): outside HTTP and HTTPS APIs through `roxum-http-client`, tokens, redirects,
  errors
- [Deployment](deployment.md): Linux builds, settings files, worker processes, reverse proxies, timeouts, logs, and
  debug mode
- [Observability](observability.md): request IDs, the access log, metrics, health checks
- [What roxum leaves out on purpose](../../README.md#limitations): HTTP/2, inbound TLS, WebSocket, and others
