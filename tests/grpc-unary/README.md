# Typed Unary service checks

`service.proto` generates Roc server registration and message codecs plus
independent Python messages and a grpcio service stub. `regenerate.py` checks the committed
Roc output byte-for-byte after formatting; `--write` updates it.

`verify.py` calls the typed service using the generated grpcio stub on TCP and Unix listeners, both directly and
through nginx TLS termination with cleartext HTTP/2 upstreams. It
checks decoded values, binary trailers, application status text, malformed and
oversized requests, invalid application outputs, unknown methods, and successful
calls after failures. Framing and metadata parser corpora remain in
`tests/grpc-wire`; timeout parsing, pre-body expiry, stale metadata-time deadlines, and suspended
handler cancellation are covered here. Raw HTTP/2 assertions require HTTP 200,
no response message, and final `grpc-status: 4` on expiry; a client-local timeout
or stream reset cannot satisfy them. TLS clients validate the ephemeral certificate
and hostname, and raw clients require ALPN `h2`. No system trust store changes,
external certificate authority, server reflection, or running proxy are needed.

`setup_proxy.py` downloads the pinned nginx source, verifies its SHA-256, and
builds a local binary under `zig-out`. It requires a C compiler, make, and OpenSSL
headers/libraries (`brew install openssl@3` on macOS, `build-essential libssl-dev`
on Debian). The Linux test image includes these dependencies. The fixture also
uses the `openssl` command to create temporary certificates. These are test-only
dependencies, not dependencies of the roxum host or integration package.

Run `python3 tools/check.py --only test-grpc-unary` for all backend/allocator
combinations. `test_generator.py` covers opt-in generation and atomic rejection
of unsupported descriptors; codec-only generation must stay platform-free.
