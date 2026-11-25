# Inbound TLS for 0.4

TCP listeners can serve HTTPS and native gRPC through the bundled Mbed TLS
engine. The host owns credentials, handshakes and encrypted I/O. See the
[deployment guide](../guides/deployment.md#inbound-tls) for listener options
and the [migration guide](../guides/migrating-to-0.4.md) for application changes.

## Acceptance checks

| Check | What it verifies |
|---|---|
| [Engine and packaging trials](inbound-tls-packaging.md) | Engine selection, bundle size and linkage on the three supported targets. The initial [OpenSSL probe](../../tests/inbound-tls/verify.py) tested ALPN and nonblocking handshake behavior. |
| [Packaged listener](inbound-tls-packaging.md#intact-host-trial) | Credential validation at startup, bounded admission, handshake timeouts, HTTPS and negotiated HTTP/2 from the extracted host. |
| `zig build test-inbound-tls-records` | Nonblocking application I/O, partial writes, buffered reads and authenticated shutdown with TLS 1.2 and 1.3 clients. |
| [Streaming gRPC](../../tests/grpc-streaming/README.md) | Direct TLS, cleartext and proxy deployments, including cancellation, final trailers, bounded memory and drain. |
| [Distributed gRPC example](../../integrations/roxum-grpc/DISTRIBUTION.md#release-compatibility-and-verification) | All four RPC forms with generated clients over direct TLS and cleartext HTTP/2. |

Run the [release verification matrix](../toolchain.md) across the supported targets.

## Public API comparison

The published 0.3.0 platform bundles its TOML dependency locally. The pinned
`roc bump` cannot compare the entire platform because the public type of
`Config.load!` refers to that dependency. A source comparison against
`v0.3.0` found changes only in `Server.roc` among the platform's Roc modules.
Comparing `Server` and its public `Http.IpAddr` dependency with `roc bump`
identified the new protocol variant and `Server.Tls` options and confirmed
that 0.4.0 satisfies the required pre-1.0 breaking-change bump.
