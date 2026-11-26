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

## 0.5 — HTTP feature completion

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

The [0.5 migration guide](../guides/migrating-to-0.5.md) records the toolchain
update and the HTTP/2 behavior changes. The following application checks cover
limits and failure behavior before performance measurement:

| Application | Acceptance evidence |
|---|---|
| HTTP | [Admission](../../tests/admission/verify.py) checks 503 responses under load and successful requests once capacity returns. The [HTTP/2 listener](../../tests/http2-listener/verify.py) checks body limits, expiry and release of writer slots. |
| SSE | The [subscription test](../../tests/sse-subscription/verify.py) checks idle disconnect and resubscription. The HTTP/2 listener check also verifies that keep-alives do not extend the write deadline. |
| gRPC | [Unary](../../tests/grpc-unary/README.md) and [streaming](../../tests/grpc-streaming/README.md) check wire status, message bounds and resource release after cancellation. |

Compared with `v0.4.0`, the Roc source changes in the platform are confined to
the internal file-response path and API comments. The platform entry contract
and integration APIs are unchanged. RC2's `roc bump` reports no API change for
`Server` with `Http.IpAddr`. It cannot compare the complete platform because
`Config.load!` exposes a type from the local TOML package.

## 0.6 — HTTP performance

The [0.6 performance plan](performance-0.6.md) defines the axum comparison,
workloads and acceptance criteria. Close the phase with measured parity or a
reproducible Roc constraint and a concrete test for reopening each remaining
gap. The results become the baseline for refactoring.

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
