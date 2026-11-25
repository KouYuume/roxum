# Documentation

## Using roxum

- [Getting started](guides/getting-started.md), [toolchain setup](toolchain.md), and migration guides for [0.2](guides/migrating-to-0.2.md), [0.3](guides/migrating-to-0.3.md), and [0.4](guides/migrating-to-0.4.md)
- [Routing](guides/routing.md), [extractors](guides/extractors.md), [responses](guides/responses.md), and [middleware](guides/middleware.md)
- [Streaming](guides/streaming.md), [files and compression](guides/files.md), and [static pages](guides/static-pages.md)
- [Unary and streaming gRPC](../integrations/roxum-grpc/README.md), [runnable service](../integrations/roxum-grpc/example/README.md), and [distribution](../integrations/roxum-grpc/DISTRIBUTION.md)
- [Database](guides/database.md) and [HTTP client](guides/http-client.md)
- [Deployment](guides/deployment.md), [reverse proxies](guides/reverse-proxy.md), and [observability](guides/observability.md)

## Design and contracts

These documents describe the current implementation, its invariants, and the project's scope policies.

- [Architecture](design/architecture.md) and [platform boundary](design/platform-boundary.md)
- [Scope and non-goals](design/non-goals.md): backend focus, platform suggestions by use case, and responsibilities delegated to libraries and integrations
- [Public API layout](design/public-api-layout.md) and [request representation](design/request-repr.md)
- [Execution and ownership](design/execution-model.md) and [I/O scheduling](design/io-execution.md)
- [Internal HTTP/2 engine](design/http2-engine.md): ownership, limits, production listeners, and [finite adapters](design/http2-finite.md)
- [HTTP/2 streaming](design/http2-streaming.md): incremental input/output, duplex coordination and request lifecycles
- [Streaming lifecycle](design/streaming.md) and [HTTP field lists](design/http-field-lists.md)
- [Independent Protobuf distribution](../libraries/roc-protobuf/DISTRIBUTION.md): codec/tool compatibility, standalone setup, and artifact metadata
- [Versioning](design/versioning.md) and [integration releases](design/integration-releases.md)
- [Contributing](contributing.md): local checks before pushing, and what CI runs

## Implementation plans

These documents describe implementation plans, acceptance evidence, and remaining
gates. Completed evidence is distinguished from proposed capabilities.

- [Roadmap to 1.0](plans/roadmap-to-1.0.md) covers inbound TLS, HTTP feature completion, performance, refactoring and release criteria.
- [0.4 inbound TLS](plans/inbound-tls-0.4.md) covers packaging, transport acceptance and the public API comparison.
- [gRPC server support](plans/grpc.md): host/integration boundaries, transport, codec, and service milestones
- [0.3 gRPC streaming](plans/grpc-streaming-0.3.md): production acceptance, distribution, and release gates
- [Protobuf codec and generator assessment](plans/protobuf-codegen.md): reuse inventory, design decision, and codec acceptance evidence
- [Finite HTTP/2 acceptance](plans/http2-finite-acceptance.md): milestone 1 transport evidence and limits
- [HTTP/2 transport decision](plans/http2-transport.md): engine choice, isolated spike evidence, and links to implemented contracts

## Performance

- [Comparison with axum and Go](comparison.md): each criterion, its sources, and the measurements
- [Performance status](performance.md): current throughput against axum, its conditions, and the known gap
- [HTTP comparison protocol](../bench/m13/protocol.md): workload contracts, fairness, trial acceptance, and the optimization workflow
- [Performance investigation](../bench/m13/investigation.md): measurement resolution, cost attribution, and optimization acceptance
