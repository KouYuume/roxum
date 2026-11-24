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
HTTP engine, or failure. The trial drives these waits with poll.

Add an opt-in TCP listener setting with certificate chain and private key paths.
Define the protocol choice alongside existing cleartext settings, handshake
timeout and concurrency limit, their defaults and valid ranges. Validate
configuration and key/certificate pairing before reporting readiness. Exercise
missing, unreadable, malformed and mismatched files. Document certificate
renewal by replacement and process restart, and keep key bytes out of Roc
model values, logs and diagnostics. Regenerate glue and verify the ABI.

Give each accepted connection a single session owner, a monotonic absolute
handshake deadline and a bounded admission slot. Drive read and write waits from
kqueue/epoll. Verify a healthy client progresses while another stalls, quota
recovery after failure, and cleanup on peer close, timeout and worker drain.

## 4. Serve HTTP and gRPC through the negotiated transport

Dispatch each connection to the existing HTTP engine after negotiation.
Route all reads and writes through its TLS session, accounting for buffered
plaintext, partial writes, opposite-direction readiness and terminal output.
Check HTTP/1.1 keep-alive and an HTTPS route with a verifying client. Check
HTTP/2 with an independent gRPC client, including streaming, backpressure,
cancellation, trailers and graceful shutdown. Retain cleartext and proxy
regressions and run the lifecycle checks with both allocators.

## 5. Accept and distribute 0.4

Run the [toolchain matrix](../toolchain.md) and exercise direct TLS from
extracted bundles on supported targets. Publish the listener examples,
certificate rotation procedure, operational limits, updated compatibility
manifest, migration guidance and changelog. Review the public API and versions
under the [release policy](../design/versioning.md) before promoting develop.
