# Comparison with axum and Go

This page compares roxum with [axum](https://docs.rs/axum/latest/axum/) and Go's standard [`net/http`](https://pkg.go.dev/net/http). roxum's maintainers wrote it; read it with that in mind, and check the linked sources.

Ratings describe each criterion, not overall quality; additional libraries can change them.

**◎** Direct support · **○** Ordinary implementation or configuration · **△** Extra implementation, conventions, or infrastructure

## Language and correctness

| Criterion | roxum | axum | Go |
|---|---|---|---|
| Declarative HTTP inputs and JSON replies | ◎ Extractors / `Reply.json` | ◎ Extractors / `Json<T>` | ○ Explicit decoding / helpers |
| Pure domain logic enforced | ◎ Compiler checks (`crash`, `dbg`, and `expect` stay allowed) | △ Conventions / review | △ Conventions / review |
| Errors handled, as the types require | ◎ `Try`, `?`, and `match` | ◎ [`Result` and `?`](https://doc.rust-lang.org/book/ch09-02-recoverable-errors-with-result.html); an unused `Result` only warns | △ A bare call or `_` drops an error; errcheck (a golangci-lint default) |
| No null dereferences at runtime | ◎ No null | ◎ [`Option`](https://doc.rust-lang.org/std/option/) | △ A nil pointer or map can panic |
| No data races between threads | ◎ Immutable values; an app that puts a function in a `Box` runs one thread per process ([deployment](guides/deployment.md)) | ◎ [`Send` / `Sync`](https://doc.rust-lang.org/nomicon/send-and-sync.html) checked at compile time | △ Found at runtime by the [race detector](https://go.dev/doc/articles/race_detector) |
| Every case of a variant handled | ◎ Exhaustive `match` on tags | ◎ Exhaustive `match` on enums | △ No sum types; linters |
| When invalid or conflicting routes are caught | At build time, for top-level routers | At startup: [panic when the router is built](https://docs.rs/axum/latest/axum/routing/struct.Router.html#panics) | At startup: [panic when registered](https://pkg.go.dev/net/http#ServeMux.Handle) |

## Web features and operation

| Criterion | roxum | axum | Go |
|---|---|---|---|
| Sequential I/O code | ◎ Fibers (cooperative) | ○ `async` / `.await`: sequential, with coloured functions and `Send` futures | ◎ Goroutines |
| Long computations interrupted | △ No: a fiber runs until it waits for I/O | △ No: it holds the runtime's worker unless moved to `spawn_blocking` | ◎ Goroutines are preempted |
| Middleware composition | ◎ Layers | ◎ Layers / `ServiceBuilder` | ◎ Handler wrappers |
| Middleware selected by typed route tags and body stages | ◎ Typed tags + four stages | ○ `route_layer`, nested routers, body wrappers | ○ Handler wrappers |
| Existing middleware reuse | △ roxum's own integrations only | ◎ [Tower / tower-http](https://docs.rs/axum/latest/axum/middleware/index.html) | ◎ `http.Handler` ecosystem |
| DDD layers and replaceable dependencies | ○ Functions | ○ Traits / functions | ○ Interfaces / functions |
| Automatic memory cleanup | ◎ Reference counting + request arena | ◎ [Ownership / drop](https://doc.rust-lang.org/book/ch04-01-what-is-ownership.html) | ◎ [GC](https://go.dev/doc/gc-guide) |
| Inbound TLS | △ [Reverse proxy](guides/reverse-proxy.md) | ○ rustls / axum-server | ◎ `ListenAndServeTLS` |
| HTTP/2 | △ Opt-in cleartext, finite responses; no trailers/gRPC yet | ○ `http2` feature / transport setup | ◎ Automatic with HTTPS |
| WebSocket | △ Not supported | ◎ `ws` feature / `extract::ws` | ○ `golang.org/x/net/websocket` or third-party packages |
| IPv6 and Unix domain listeners | ○ IPv4/IPv6 TCP and filesystem Unix listeners | ◎ | ◎ |
| HTTP tests without a server | △ No test harness; `Router.dispatch!` runs a request through the routes inside an app | ○ `tower::ServiceExt::oneshot` | ◎ `net/http/httptest` |
| Profiling and debugging | ○ Access log, metrics, `roxum-trace` ([observability](guides/observability.md)) | ◎ `tracing` ecosystem, native debuggers | ◎ `net/http/pprof`, runtime trace, Delve |
| Supported systems | △ Apple silicon macOS; arm64 and x86_64 Linux with musl | ◎ | ◎ |
| Maturity and API stability | △ 0.1.0, on a pinned Roc nightly | ○ 0.x, widely deployed | ◎ [Go 1 compatibility promise](https://go.dev/doc/go1compat) |

Equivalent tag and body-stage hooks in axum or Go need custom implementation. Memory ratings concern cleanup, not consumption.

## Builds and performance

These are measurements, not ratings. The conditions are in [performance status](performance.md).

| Measurement | roxum | axum | Go |
|---|---|---|---|
| Throughput, fixed responses, two cores | 0.73–0.96 times axum's; p99 latency higher except with 1,000 connections | Baseline | Not measured |
| Rebuild after a one-line edit, development | 0.6–0.8 s (`--opt=dev`) | 0.5–0.7 s (debug) | 0.2–0.4 s |
| Rebuild after a one-line edit, optimized | 3.1–3.8 s (`--opt=speed`) | 6.1–8.1 s (release, fat LTO, one codegen unit) | 0.2–0.4 s |
| Rebuild with no change, optimized | 3.0–3.6 s | 0.03–0.06 s | 0.07–0.10 s |
| First optimized build, from empty caches | 3.3–4.1 s; the host comes built in the platform's bundle | 14–18 s, compiling the dependencies, which later builds reuse | 4.9–5.1 s, compiling the standard library, which other projects reuse |
| Binary size, Linux, stripped | 1.8 MB, static | 1.0 MB, static (musl) | 4.9 MB, static |

- Build times and sizes are medians for one small app (38–63 lines) on macOS and Linux, given as a range. How they grow with an application was not measured.
- axum's release profile is its slowest one; a default `cargo build --release` was not measured.
- The toolchains were Rust 1.97.1 and 1.99.1 and Go 1.23.12, older than the current Go release.
- Throughput compares fixed responses on one pair of AWS hosts; see [performance status](performance.md) for the workloads, p99 latencies, and what is not yet measured.
