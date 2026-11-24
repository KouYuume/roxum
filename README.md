# roxum

English | [日本語](README.ja.md)

roxum is a web server platform that aims to fit the philosophy of [Roc](https://github.com/roc-lang/roc): concise application code, pure business logic, and explicit effects. Typed handlers express HTTP behavior, while the platform manages I/O and execution.

Its focus is independently deployable HTTP APIs and backend services. See [scope and non-goals](docs/design/non-goals.md) for its boundaries, and [choosing a Roc platform](docs/design/non-goals.md#choosing-a-roc-platform-for-your-application) for browser UI and hypermedia application options such as Joy and roux.

## High-level features

- **Less plumbing.** Typed extractors, automatic JSON encoding, and `Try(Reply, Reply)` keep request handling concise.
- **DDD with small functions.** Pure domain functions and function-based DI keep layers easy to connect and test. Roc rejects I/O in pure functions. See the [DDD example](examples/ddd/README.md).
- **Shorter development cycles.** `--opt=dev` skips LLVM optimization; application-only edits reuse the built Zig host.
- **Sequential I/O.** Request fibers suspend during I/O waits, so application code needs no `async` / `await`.
- **Build-time route checks.** Invalid patterns and duplicate routes fail compilation when routers are top-level values.
- **Tags and staged middleware.** Filter by application-defined typed tags and place work at `BeforeBody`, `OnChunk`, `AfterBody`, or `AfterHandler`. See [middleware](docs/guides/middleware.md) and the [tags and middleware example](examples/middleware/README.md).

HTTP/1.1 is the default and supports streaming, SSE, and file serving. [Opt-in cleartext HTTP/2](docs/guides/deployment.md#opt-in-http2) supports incremental input and output, trailers, and all four uncompressed gRPC forms. Both listeners support IPv4/IPv6 TCP and filesystem Unix sockets.

## Comparison with axum and Go

roxum combines typed HTTP handling with Roc's enforced purity and explicit effects.
It is a young platform with a smaller ecosystem and a narrower transport scope.
See the [comparison](docs/comparison.md) for feature tradeoffs and
[performance status](docs/performance.md) for workload-specific measurements.

## Quick start

roxum is under development. Use Zig 0.17.1 and the [pinned Roc revision](.roc-revision); follow the [toolchain setup](docs/toolchain.md). Supported targets are Apple silicon macOS and arm64 / x86_64 Linux with musl.

From the repository root:

```sh
zig build host
roc build --opt=dev --output=hello examples/hello/app.roc
./hello
```

The [hello example](examples/hello/app.roc) defines its route as:

```roc
routes : Router(Model, [], {})
routes = Router.new
	.route("/", MethodRouter.get(Handler.static(|{}| Reply.text("Hello, Roc!\n"))))
```

Use the printed port with `curl http://127.0.0.1:<port>/`; stop with Ctrl-C. Use `--opt=speed` for optimized builds. Rebuild the host when its sources or compiler ABI change.

Next: [getting started](docs/guides/getting-started.md) · [hello](examples/hello/README.md) · [DDD](examples/ddd/README.md) · [tags and middleware](examples/middleware/README.md) · [all documentation](docs/README.md).

## Integrations

| Area | Packages |
|---|---|
| RPC | [gRPC](integrations/roxum-grpc/README.md) · [example](integrations/roxum-grpc/example/README.md) |
| Data and external APIs | [PostgreSQL](integrations/roxum-postgres/README.md), [HTTP client](integrations/roxum-http-client/README.md) |
| Browser clients | [CORS](integrations/roxum-cors/README.md), [cookies](integrations/roxum-cookie/README.md), [server-sent events](integrations/roxum-sse/README.md) |
| Traffic control | [Rate limits](integrations/roxum-rate-limit/README.md), [concurrency limits](integrations/roxum-concurrency-limit/README.md) |
| Request and response handling | [Path normalization](integrations/roxum-normalize-path/README.md), [proxy headers](integrations/roxum-proxy-headers/README.md), [response headers](integrations/roxum-set-header/README.md), [tracing](integrations/roxum-trace/README.md) |

Core and integrations are versioned independently. See [versioning](docs/design/versioning.md) and [integration releases](docs/design/integration-releases.md).

## Limitations

- Terminate inbound TLS and HTTP/3 at a [reverse proxy](docs/guides/reverse-proxy.md). HTTP/1 trailers are unsupported. WebSocket server support, CONNECT, TRACE, and arbitrary extension methods are [excluded unless strong demand emerges](docs/design/non-goals.md#features-excluded-unless-strong-demand-emerges).
- Timeouts cannot forcibly interrupt arbitrary Roc computation.
- Runtime compression is gzip; precompressed Brotli is supported, multipart byte ranges are not.
- Sessions, CSRF, OAuth, JWT, and OpenAPI belong in libraries or integrations; see the [scope policy](docs/design/non-goals.md#features-owned-by-libraries-and-integrations).
- All files under a serving root, including dotfiles, are public. Keep private files outside it.

## Contributing and support

For a bug report, include a minimal reproducer, toolchain revisions, OS, command
and output. Remove credentials from logs. For changes, follow the
[project rules](AGENTS.md), [Roc coding rules](roc_coding_rules.md) and
[local verification and PR workflow](docs/contributing.md).

## License

roxum is licensed under the [MIT License](LICENSE).
