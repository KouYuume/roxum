# Documentation

## Using roxum

- [Getting started](guides/getting-started.md) and [toolchain setup](toolchain.md)
- [Routing](guides/routing.md), [extractors](guides/extractors.md), [responses](guides/responses.md), and [middleware](guides/middleware.md)
- [Streaming](guides/streaming.md), [files and compression](guides/files.md), and [static pages](guides/static-pages.md)
- [Database](guides/database.md) and [HTTP client](guides/http-client.md)
- [Deployment](guides/deployment.md), [reverse proxies](guides/reverse-proxy.md), and [observability](guides/observability.md)

## Design and contracts

These documents describe the current implementation and its invariants.

- [Architecture](design/architecture.md) and [platform boundary](design/platform-boundary.md)
- [Public API layout](design/public-api-layout.md) and [request representation](design/request-repr.md)
- [Execution and ownership](design/execution-model.md) and [I/O scheduling](design/io-execution.md)
- [Streaming lifecycle](design/streaming.md) and [HTTP field lists](design/http-field-lists.md)
- [Versioning](design/versioning.md) and [integration releases](design/integration-releases.md)
- [Contributing](contributing.md): local checks before pushing, and what CI runs

## Performance

- [Comparison with axum and Go](comparison.md): each criterion, its sources, and the measurements
- [Performance status](performance.md): current throughput against axum, its conditions, and the known gap
- [HTTP comparison protocol](../bench/m13/protocol.md): workload contracts, fairness, trial acceptance, and the optimization workflow
- [Performance investigation](../bench/m13/investigation.md): measurement resolution, cost attribution, and optimization acceptance
