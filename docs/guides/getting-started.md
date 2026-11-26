# Getting started

A roxum application supplies an `init!` function and a router of handlers in Roc.
The Zig host runs the workers, serves HTTP/1.1 by default, and can serve HTTP/2.

## Requirements

- The pinned Roc compiler and, for source builds, Zig and the [host build tools](../toolchain.md#setup)
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
		endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 0 }),
		timeouts: Server.Timeouts.defaults,
		limits: Server.Limits.defaults,
	},
})

routes : Router(Model, [], {})
routes = Router.new
	.route("/", MethodRouter.get(Handler.static(|{}| Reply.text("Hello, Roc!\n"))))
```

- Each worker runs `init!` once. It returns the shared `Model` and listener settings. Port `0` picks a free port.
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

Stop the server with Ctrl-C. Use `--opt=dev` for faster local builds. The default,
`--opt=speed`, optimizes for execution speed.

## Distribution

For URL imports, take the platform and integration URLs from the same release's
`release.json`. The platform bundle includes the host archives. See [integration releases](../design/integration-releases.md).

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
| `Handler.duplex` | `{ begin!, ready! }` | independent request and response streaming over [HTTP/2](streaming.md#independent-http2-input-and-output) |

Buffered handlers receive the whole body, up to `Server.Limits.maximum_body_bytes`
(2 MiB by default). Streaming and duplex handlers receive input incrementally.

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

Use [routing](routing.md) to add a route, [extractors](extractors.md) to validate its inputs,
and [responses](responses.md) to build its reply. The [documentation index](../README.md)
covers middleware, integrations and deployment.
