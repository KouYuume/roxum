# Roadmap to roxum 1.0

Roxum 1.0 should let an application ship an independent HTTP backend over
direct HTTPS or behind a reverse proxy, with public APIs and observable
behavior that users can rely on across compatible 1.x updates. The starting
point is the [0.3 release](grpc-streaming-0.3.md), which brings incremental
HTTP/2 I/O and all four uncompressed gRPC server call forms.

## 0.4 — inbound TLS

Add TLS to TCP listeners and negotiate HTTP/1.1 or HTTP/2 through ALPN.
Define certificate and key configuration, startup failures, certificate
renewal procedures, handshake deadlines and concurrent handshake limits.
The host owns each connection from acceptance through shutdown.

Verify a regular HTTPS route and a gRPC call with independent clients.
Exercise a stalled handshake alongside a healthy client, and verify cleanup
on timeout, disconnect and shutdown. Keep proxy deployments covered by the
existing [deployment checks and guidance](../guides/deployment.md).

## Complete the HTTP feature set

- Support file responses and SSE writer options over HTTP/2. Exercise the same
  application routes over HTTP/1.1 and HTTP/2, including a slow reader and a
  disconnect. Verify bounded file reads and release of file and stream resources.
- Exercise an SSE subscription in which a separate request publishes an event.
  Check delivery and cleanup when the subscriber leaves. The application or an
  external service owns subscriptions and history.
- Give application authors a supported way to exercise finite HTTP routes
  without opening a port. Start with the existing `Router.dispatch!` and a
  runnable example covering a successful response, extractor rejection and
  middleware short-circuit. Add public API only if the example requires it.

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

After 0.4, phase names describe the order of work. Actual public changes
determine the intervening 0.x version numbers. The [scope policy](../design/non-goals.md)
records which capabilities belong to other projects and when deferred
protocols merit reconsideration.
