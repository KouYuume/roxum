# roxum

English | [日本語](README.ja.md)

roxum is a web server platform that aims to fit the philosophy of [Roc](https://github.com/roc-lang/roc): concise application code, pure business logic, and explicit effects. Typed handlers express HTTP behavior, while the platform manages I/O and execution.

## High-level features

- **Less plumbing.** Typed extractors, automatic JSON encoding, and `Try(Reply, Reply)` keep request handling concise.
- **DDD with small functions.** Pure domain functions and function-based DI keep layers easy to connect and test. Roc rejects I/O in pure functions. See the [DDD example](examples/ddd/README.md).
- **Shorter development cycles.** `--opt=dev` skips LLVM optimization; application-only edits reuse the built Zig host.
- **Sequential I/O.** Request fibers suspend during I/O waits, so application code needs no `async` / `await`.
- **Build-time route checks.** Invalid patterns and duplicate routes fail compilation when routers are top-level values.
- **Tags and staged middleware.** Filter by application-defined typed tags and place work at `BeforeBody`, `OnChunk`, `AfterBody`, or `AfterHandler`. See [middleware](docs/guides/middleware.md) and the [tags and middleware example](examples/middleware/README.md).

The host also provides request-scoped memory reuse and cleanup. Streaming, SSE, file serving, gzip, PostgreSQL, and outbound HTTPS are supported. See the [architecture](docs/design/architecture.md) and [memory model](docs/design/execution-model.md).

## Comparison with axum and Go

Like axum, roxum takes handlers' inputs as types and has Rust's kind of type-level checks that Go lacks (errors, null, data races, exhaustive matching). Beyond axum, the compiler keeps domain code pure, and routes are checked at build time. In exchange, roxum has no inbound TLS, HTTP/2, WebSocket, or IPv6 (put a reverse proxy in front for TLS and HTTP/2), reuses only its own integrations, and is young. Its runtime performance does not reach axum's yet: on fixed-response workloads with two cores, its throughput was 73–96% of axum's. Optimized builds take about 3 seconds even when nothing changed.

See the [comparison](docs/comparison.md) for each criterion and its sources, and [performance status](docs/performance.md) for the measurements.

## Quick start

roxum is under development. Use Zig 0.16.0 and the [pinned Roc revision](.roc-revision); follow the [toolchain setup](docs/toolchain.md). Supported targets are Apple silicon macOS and arm64 / x86_64 Linux with musl.

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
| Data and external APIs | [PostgreSQL](integrations/roxum-postgres/README.md), [HTTP client](integrations/roxum-http-client/README.md) |
| Browser clients | [CORS](integrations/roxum-cors/README.md), [cookies](integrations/roxum-cookie/README.md), [server-sent events](integrations/roxum-sse/README.md) |
| Traffic control | [Rate limits](integrations/roxum-rate-limit/README.md), [concurrency limits](integrations/roxum-concurrency-limit/README.md) |
| Request and response handling | [Path normalization](integrations/roxum-normalize-path/README.md), [proxy headers](integrations/roxum-proxy-headers/README.md), [response headers](integrations/roxum-set-header/README.md), [tracing](integrations/roxum-trace/README.md) |

Core and integrations are versioned independently. See [versioning](docs/design/versioning.md) and [integration releases](docs/design/integration-releases.md).

## Limitations

- IPv4 and HTTP/1.1 only; use a [reverse proxy](docs/guides/reverse-proxy.md) for inbound TLS, HTTP/2, or HTTP/3.
- No Unix domain listeners, WebSocket, CONNECT, TRACE, extension methods, or HTTP trailers.
- Timeouts cannot forcibly interrupt arbitrary Roc computation.
- Runtime compression is gzip; precompressed Brotli is supported, multipart byte ranges are not.
- Sessions, CSRF protection, OAuth, JWT, and OpenAPI are not built into the core.
- All files under a serving root, including dotfiles, are public. Keep private files outside it.

## Contributing and support

Open an issue with a minimal reproducer, toolchain revisions, OS, command, and output. Remove credentials before sharing logs. Before contributing, read [project rules](AGENTS.md) and [Roc coding rules](roc_coding_rules.md); include relevant tests and documentation, and keep both READMEs in sync.

```sh
zig build test
zig build test-e2e
zig build test-e2e -Dcontract-alloc=true
zig build test-contract
```

The full checks cover `speed`, `dev`, and `interpreter`; run them before pushing, as described in [contributing](docs/contributing.md). Release checks: `tools/release-check.sh`; Linux: `tools/linux/run-tests.sh`; fuzzing: `zig build fuzz` then `tools/fuzz.sh 10000`.

## License

roxum is licensed under the [MIT License](LICENSE).
