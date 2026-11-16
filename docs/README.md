# Documentation

## Using roxum

- [Getting started](guides/getting-started.md), [toolchain setup](toolchain.md), and [migrating from 0.1 to 0.2](guides/migrating-to-0.2.md)
- [Routing](guides/routing.md), [extractors](guides/extractors.md), [responses](guides/responses.md), and [middleware](guides/middleware.md)
- [Streaming](guides/streaming.md), [files and compression](guides/files.md), and [static pages](guides/static-pages.md)
- [Unary gRPC](../integrations/roxum-grpc/README.md), [runnable service](../integrations/roxum-grpc/example/README.md), and [distribution](../integrations/roxum-grpc/DISTRIBUTION.md)
- [Database](guides/database.md) and [HTTP client](guides/http-client.md)
- [Deployment](guides/deployment.md), [reverse proxies](guides/reverse-proxy.md), and [observability](guides/observability.md)

## Design and contracts

These documents describe the current implementation, its invariants, and the project's scope policies.

- [Architecture](design/architecture.md) and [platform boundary](design/platform-boundary.md)
- [Scope and non-goals](design/non-goals.md): backend focus, platform suggestions by use case, and responsibilities delegated to libraries and integrations
- [Public API layout](design/public-api-layout.md) and [request representation](design/request-repr.md)
- [Execution and ownership](design/execution-model.md) and [I/O scheduling](design/io-execution.md)
- [Internal HTTP/2 engine](design/http2-engine.md): dependency, ownership, limits, and finite production listener integration
- [HTTP/2 streaming](design/http2-streaming.md): internal incremental output and target 0.3 API/lifecycle contracts
- [Streaming lifecycle](design/streaming.md) and [HTTP field lists](design/http-field-lists.md)
- [Independent Protobuf distribution](../libraries/roc-protobuf/DISTRIBUTION.md): codec/tool compatibility, standalone setup, and artifact metadata
- [Versioning](design/versioning.md) and [integration releases](design/integration-releases.md)
- [Contributing](contributing.md): local checks before pushing, and what CI runs

## Implementation plans

These documents describe implementation plans, acceptance evidence, and remaining
gates. Completed evidence is distinguished from proposed capabilities.

- [gRPC server support](plans/grpc.md): host/integration boundaries, completed Unary gates, and planned streaming scope
- [0.3 gRPC streaming](plans/grpc-streaming-0.3.md): server/client/bidirectional scope, PR sequence and acceptance gates
- [Protobuf codec and generator assessment](plans/protobuf-codegen.md): reuse inventory, schema target, decoder bounds, and milestone 2 implementation slices
- [Finite HTTP/2 acceptance](plans/http2-finite-acceptance.md): milestone 1 transport evidence and limits
- [HTTP/2 transport decision](plans/http2-transport.md): engine choice, isolated spike evidence, and links to implemented contracts

## Performance

- [Comparison with axum and Go](comparison.md): each criterion, its sources, and the measurements
- [Performance status](performance.md): current throughput against axum, its conditions, and the known gap
- [HTTP comparison protocol](../bench/m13/protocol.md): workload contracts, fairness, trial acceptance, and the optimization workflow
- [Performance investigation](../bench/m13/investigation.md): measurement resolution, cost attribution, and optimization acceptance
