# Inbound TLS for 0.4

The [1.0 roadmap](roadmap-to-1.0.md) calls for direct HTTPS and native gRPC
on TCP. Keep the 0.3 cleartext HTTP/1.1 and prior-knowledge HTTP/2 listeners,
Unix sockets and proxy deployments working. The host owns keys, handshakes and
encrypted I/O. Application handlers keep the existing HTTP API.

## 1. Verify handshake and protocol selection

The [isolated probe](../../tests/inbound-tls/verify.py) compiles a small server
with the pinned Zig C compiler and the local OpenSSL development library. Each
case starts with a nonblocking socket and verifies that the server yields for
read readiness before a certificate-verifying Python client sends ClientHello.
The probe requires TLS 1.2 or later and uses this selection policy:

| Client ALPN offer | Listener dispatch |
|---|---|
| Both protocols, including HTTP/1.1 first | Prefer h2 |
| Only h2 or only HTTP/1.1 | Use the offered protocol |
| No ALPN extension | Use HTTP/1.1; no protocol is negotiated on the wire |
| Extension with no supported protocol | Fail the handshake with no_application_protocol |

Run `python3 tests/inbound-tls/verify.py` from the repository root with Zig
0.17.1, Python, the OpenSSL CLI and development headers/libraries. For a
nonstandard library location, point pkg-config at its openssl.pc. The test
uses a temporary certificate and connected local sockets. It exercises library
negotiation and resumption of a handshake after a read wait. TCP accept,
application traffic and roxum's event loop are covered by later phases.
See the OpenSSL [handshake](https://docs.openssl.org/3.5/man3/SSL_accept/) and
[ALPN callback](https://docs.openssl.org/3.5/man3/SSL_CTX_set_alpn_select_cb/) contracts.

## 2. Select and package the server engine

The [packaging trials](inbound-tls-packaging.md) exercise Mbed TLS in the
extracted Roc application on all three targets. The standard bundle ships the
server engine under a 17 MB expanded budget. Production connections should use the
host's readiness and deadline machinery. The existing
[outbound TLS module](../../platform/host/tls.zig) wraps a client session.

## 3. Configure credentials and admit connections

The packaged host includes a worker-owned credential configuration. The
[trial listener](inbound-tls-packaging.md#intact-host-trial) exercises startup
failure and reuses the validated pair across sessions. Each handshake borrows
the nonblocking socket and returns a read wait, a write wait, the negotiated
HTTP engine, or failure. The trial listener resumes pending handshakes on the
worker's kqueue/epoll poller. Pending sessions occupy connection slots and
have a separate per-worker cap and an absolute monotonic deadline. Drain
closes unfinished sessions.

TCP listeners select TLS through `Server.Protocol.Tls`. The
[deployment guide](../guides/deployment.md#inbound-tls-on-the-04-development-branch)
describes credential paths, rotation and handshake limits. Only paths cross the Roc/host boundary. The worker owns key material.

## 4. Serve HTTP and gRPC through the negotiated transport

The host's TLS session adapter supports nonblocking application reads, writes
and `close_notify`. A partial write consumes only the reported plaintext bytes.
After a readiness wait, the caller retries the same write buffer and length.
Before idling after a successful read, it checks the session for buffered data.
A peer's `close_notify` ends inbound plaintext cleanly. A bare socket EOF
reports failure. Run `zig build test-inbound-tls-records` to exercise this
contract with a verifying TLS 1.2 and 1.3 client.

HTTP/1.1 uses the negotiated session for request heads, bodies and response
writes. The listener tests exercise keep-alive, 100 Continue, an echoed body,
streamed output and TLS shutdown. The worker releases the handshake slot
before dispatch and owns the session until connection cleanup.

Negotiated h2 sessions use the existing HTTP/2 engine. The listener tests
exercise concurrent streams and authenticated TLS shutdown. The
[gRPC streaming suite](../../tests/grpc-streaming/README.md) exercises direct
TLS with generated clients and a peer that controls HTTP/2 stream credit.
It checks cancellation, final trailers, bounded memory and active RPCs during
drain across the configured backends and both allocators. The same suite keeps
the cleartext and proxy deployments under test.

## 5. Accept and distribute 0.4

Run the [toolchain matrix](../toolchain.md) and exercise direct TLS from
extracted bundles on supported targets. Publish the listener examples,
certificate rotation procedure, operational limits, updated compatibility
manifest, migration guidance and changelog. Review the public API and versions
under the [release policy](../design/versioning.md) before promoting develop.
