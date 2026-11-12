# Documentation

## Using roxum

- [Getting started](guides/getting-started.md) and [toolchain setup](toolchain.md)
- [Routing](guides/routing.md), [extractors](guides/extractors.md), [responses](guides/responses.md), and [middleware](guides/middleware.md)
- [Streaming](guides/streaming.md), [files and compression](guides/files.md), and [static pages](guides/static-pages.md)
- [Database](guides/database.md) and [HTTP client](guides/http-client.md)
- [Deployment](guides/deployment.md), [reverse proxies](guides/reverse-proxy.md), and [observability](guides/observability.md)

## Design and contracts

These documents describe the current implementation, its invariants, and the project's scope policies.

- [Architecture](design/architecture.md) and [platform boundary](design/platform-boundary.md)
- [Scope and non-goals](design/non-goals.md): backend focus, platform suggestions by use case, and responsibilities delegated to libraries and integrations
- [Public API layout](design/public-api-layout.md) and [request representation](design/request-repr.md)
- [Execution and ownership](design/execution-model.md) and [I/O scheduling](design/io-execution.md)
- [Internal HTTP/2 engine](design/http2-engine.md): dependency, ownership, limits, and finite production listener integration
- [Streaming lifecycle](design/streaming.md) and [HTTP field lists](design/http-field-lists.md)
- [Versioning](design/versioning.md) and [integration releases](design/integration-releases.md)
- [Contributing](contributing.md): local checks before pushing, and what CI runs

## Implementation plans

These documents describe implementation plans, acceptance evidence, and remaining
gates. Completed evidence is distinguished from proposed capabilities.

- [gRPC server support](plans/grpc.md): host/integration boundaries, Unary RPC first, and staged streaming support
- [Finite HTTP/2 acceptance](plans/http2-finite-acceptance.md): milestone 1 evidence and limits before codec/generator work
- [HTTP/2 transport decision](plans/http2-transport.md): milestone 0 evidence, engine choice, and proposed ownership/API contracts

## Performance

- [Comparison with axum and Go](comparison.md): each criterion, its sources, and the measurements
- [Performance status](performance.md): current throughput against axum, its conditions, and the known gap
- [HTTP comparison protocol](../bench/m13/protocol.md): workload contracts, fairness, trial acceptance, and the optimization workflow
- [Performance investigation](../bench/m13/investigation.md): measurement resolution, cost attribution, and optimization acceptance
