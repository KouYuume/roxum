# Roadmap to roxum 1.0

Roxum 1.0 should let an application ship an independent HTTP backend over
direct HTTPS or behind a reverse proxy, with public APIs and observable
behavior that users can rely on across compatible 1.x updates. The starting
point is the [0.3 release](grpc-streaming-0.3.md), which brings incremental
HTTP/2 I/O and all four uncompressed gRPC server call forms.

## 0.4 — inbound TLS

TCP listeners can serve HTTPS and native gRPC directly. The host loads the
credentials, bounds concurrent handshakes and negotiates HTTP/1.1 or HTTP/2.
See the [deployment guide](../guides/deployment.md#inbound-tls) for configuration
and the [0.4 acceptance checks](inbound-tls-0.4.md) for verification.

## 0.5 target — complete the HTTP feature set

- [File responses](../guides/files.md#serving-a-directory) serve known-length files over
  HTTP/1.1 and HTTP/2, including ranges and precompressed files.
- [SSE writers](../guides/streaming.md#server-sent-events) support periodic keep-alive
  comments and graceful drain over HTTP/1.1 and HTTP/2.
- The [SSE subscription test](../guides/streaming.md#publishing-from-another-request)
  checks delivery from a separate publishing request and cleanup when an idle
  subscriber disconnects over HTTP/1.1 or HTTP/2.
- [Finite route tests](../guides/routing.md#testing-route-responses) use `Router.dispatch!`
  to check handler responses, extractor rejection and middleware short-circuiting
  without opening a listener.

Review limits, defaults, errors and cancellation with representative HTTP,
SSE and gRPC applications. Record intended breaking changes and migration
steps before taking the performance baseline.

## Improve performance

Measure the feature-complete implementation under the
[HTTP comparison protocol](../../bench/m13/protocol.md). Include dynamic JSON
with middleware and file or streaming traffic alongside fixed responses.
Record resource budgets, raw repetitions, failures, throughput, tail latency
and memory. Use the [investigation procedure](../../bench/m13/investigation.md)
to attribute a reproducible bottleneck before optimizing it.

Close the phase with before/after measurements for each retained optimization,
correctness checks and results for other affected workloads. Record remaining
gaps and the conditions of the measurements in [performance status](../performance.md).
These results serve as the baseline for the refactoring phase.

## Refactor before 1.0

Use the completed feature paths and measurements to locate duplicated
lifecycle logic, unclear ownership or public exposure of host details.
Choose refactorings against specific findings and preserve the HTTP behavior
recorded in the feature phase. Check the affected ownership, cancellation and
ABI contracts, then rerun the affected performance workloads against the
previous phase's baseline. Resolve unexplained regressions before release.

## Release 1.0

Review the public API, application entry contracts, defaults and error behavior
against the last 0.x release. Finish the migration guide and validate the
distributed platform with the compatible integrations and pinned toolchain.
Run the [release verification matrix](../toolchain.md) on the supported macOS
and Linux targets. Publish the supported combination and its compatibility
commitments under the [versioning policy](../design/versioning.md).

Later phases describe the order of work. Public changes determine release
versions under the versioning policy. The [scope policy](../design/non-goals.md)
describes the core boundary. WebSocket server support is outside the 1.0 roadmap.
