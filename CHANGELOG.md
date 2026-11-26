# Changelog

Changes to the roxum platform and its integrations, newest first. The platform and each integration have their own versions; see [versioning](docs/design/versioning.md). An entry about an integration starts with its name.

## Unreleased

## 0.5.0

### Breaking changes

- Rebuild 0.4 applications with Roc `0.1.0-RC2` and the matching platform and host archives. See [migrating from 0.4](docs/guides/migrating-to-0.5.md).

### Added

- Send periodic writer keep-alives over HTTP/2, including the default SSE comment.
- End opted-in HTTP/2 response streams cleanly during graceful shutdown with `ends_on_drain`.
- Serve files over HTTP/2 with Content-Length, byte ranges and precompressed variants.
- Run application initialization once with `--check-init`. The [route response example](docs/guides/routing.md#testing-route-responses) uses it to test finite requests without opening a listener.

## 0.4.0

### Breaking changes

- `Server.Protocol` gains a `Tls(Server.Tls)` variant for TCP listeners. Update exhaustive protocol matches and rebuild with matching platform sources and host archives. See [migrating from 0.3](docs/guides/migrating-to-0.4.md).

### Added

- TCP listeners can serve HTTPS and native gRPC with TLS 1.2 or 1.3. ALPN selects HTTP/2 or HTTP/1.1. Each worker validates the certificate chain and private key at startup and limits pending handshakes. See [deployment](docs/guides/deployment.md#inbound-tls).

## 0.3.0

### Breaking changes

- Upgrade to Roc `0.1.0_RC1` (built from `15177e91f62cafddf5336c455e00e9f05427ac16`); Zig stays at 0.17.1. Roc 0.1 closes parser error types, fills a record's default fields only when its type is known where it is built, and evaluates expressions that do not depend on a function's arguments at compile time. Follow [migrating from 0.2](docs/guides/migrating-to-0.3.md) and rebuild applications with matching platform and integration bundles.
- Roc 0.1 links every Linux executable as a static PIE. The musl targets link `rcrt1.o`, which relocates the executable at startup, instead of `crt1.o`, with a position-independent `libc.a`; `zig build host` and the release bundles provide both.
- `HttpError` is a record with public `status` and `message` fields. Build one with `HttpError.{ status: 409, message: "..." }` and read its fields; `HttpError.make`, `HttpError.status`, and `HttpError.message` are removed.
- `Middleware.ChunkCheck.new` takes a record, `{ initial, step, finish }`.
- Parsers use one closed error type per format. `Extract.json` and `Extract.JsonBody` need `a.Json.Parseable([InvalidJson(Str)])`, and `Extract.typed_headers` and `Extract.Headers` need `a.Encoding.HttpHeader.Parseable([BadHeader, MissingHeader(Str)])`. The URL-encoded and multipart formats report a missing required field as `MissingRequiredField(name)` in their own error types.
- An app built with `--opt=interpreter` runs one thread per process: Roc's interpreter keeps a call on the thread that entered it. `Server.Threads.Fixed` above 1 stops its startup; raise `processes` to use more CPUs.
- roc-toml: `Toml.decode` and `Toml.decode_str` return the closed error types `[TomlDecode(Str), MissingRequiredField(Str)]` and `[TomlSyntax(Str), TomlDecode(Str), MissingRequiredField(Str)]`.
- roxum-postgres: rows decode with the closed error type `[PostgresDecodeFailed(Str), MissingRequiredField(Str)]`; a required column the row lacks is `MissingRequiredField(name)`.
- `Handler` gains a `Duplex` variant. Update exhaustive matches on handler variants.
- HTTP/2 streaming handlers receive body chunks before EOF. Streamed input now uses its own limit (unlimited by default) and can exceed `maximum_body_bytes`. The request-body deadline spans reception from the initial metadata, including callback time. A reset, timeout or disconnect can abandon a suspended handler. A response producer returning `Err(StreamClosed)` now aborts unfinished output. See [migrating from 0.2](docs/guides/migrating-to-0.3.md).
- roxum-grpc: 0.2.0 targets core `^0.3`. Rebuild with matching platform and integration bundles and regenerate service bindings when updating the Protobuf tools.

### Added

- `RequestExecution.decode_bytes!` runs a pure HTTP/2 request decoder with an owned input copy. Failure to allocate the heap or copy the input returns `RESOURCE_EXHAUSTED` for all four RPC forms. Unary, server-streaming and client-streaming decoders use `decode_bytes_with_response!` to send this status on allocation failure inside the codec. Bidirectional decoders use `decode_bytes_with_completion!` to finish an already started outbound message before sending the error trailers.

- A `Handler.typed` field that holds the reply of a field that failed can be typed `Try(_, Reply)`, so `?` sends that reply. `[Ok(_), Err(Reply)]` still works.
- HTTP/2 supports incremental request and response bodies, explicit response trailers, deadline trailers and independent input/output readiness through `Handler.duplex`.
- roxum-grpc: generated server-streaming, client-streaming and bidirectional services alongside Unary. The greeting example exercises all four forms with the distributed packages.
- roc-protobuf: matched 0.1.1 generator and wire library. Service generation supports all four RPC shapes. Codec-only generation remains platform-independent.

## 0.2.0

### Breaking changes

- Upgrade to Roc `9e85de7aba79eaeb8ca589ab6a1ea581274c8930` and Zig 0.17.1. `PathSegment.from_interpolation` and `QueryValue.from_interpolation` return assemblers accepting `Iter(Str)` instead of `List(Str)`; ordinary interpolation syntax is unchanged. Follow the [0.2 migration guide](docs/guides/migrating-to-0.2.md) and rebuild applications with matching platform and integration bundles.

- `Reply` includes `WithTrailers`; exhaustive matches must handle the new variant. `Http.Response` adds optional `trailers`, defaulting to an empty list. Nonempty trailers require a finite HTTP/2 response.

- roxum-proxy-headers: 0.2.0 uses the TCP/Unix peer representation in its public request types. Release bundles declare core `^0.2`; do not mix integrations from the 0.1 release with the 0.2 platform.

- `Http.Version` includes `Http20`; exhaustive matches must handle the new variant. Production HTTP/2 listeners are opt-in; HTTP/1 remains the default.

- Listener settings use `Server.Endpoint.Tcp({ address, port })` or `Server.Endpoint.Unix({ path })`; request peers use `RemoteAddr.Tcp({ ip, port })` or `RemoteAddr.Unix`. Match on the transport before using IP-based policies.

- Application and metrics listener addresses now use `IpAddr.V4` / `IpAddr.V6` instead of `Server.Ipv4Address`. Import `pf.IpAddr` and replace `Server.Ipv4Address.(a, b, c, d)` with `IpAddr.V4((a, b, c, d))`.

### Added

- roxum-grpc: finite, uncompressed typed Unary services with opt-in generated registration, bounded messages and metadata, status trailers, and pre-body deadlines. Cancellation and deadline expiry abandon suspended work; registered expiry responses deliver `DEADLINE_EXCEEDED`. Direct TCP/Unix and nginx TLS proxy acceptance use independent generated clients.

- roxum-grpc: runnable greeting service and release-artifact verification using the distributed generator and URL imports for the platform, gRPC integration and Protobuf library.

- roc-protobuf: standalone pure Roc bundle and matched protoc-gen-roc source distribution, with compiler compatibility metadata and bounded proto3 codecs including recursive messages.

- Opt-in cleartext HTTP/2 TCP/Unix listeners with finite response trailers, bounded connection/stream resources, worker scheduling, cancellation, execution deadlines and concurrent-stream shutdown. Inbound TLS remains a reverse-proxy responsibility.

- Filesystem Unix domain sockets for application and metrics listeners, with shared worker descriptors and identity-checked shutdown cleanup.
- roxum-proxy-headers: explicit `trust_unix` / `try_trust_unix` policies; ordinary CIDR trust rejects Unix forwarding headers.

- IPv6-only application and metrics listeners, preserving IPv6 peer addresses through request handling. IPv4 listener behavior is unchanged.

## 0.1.0

### Added

- The first release: a web server platform for Roc with typed handlers and extractors, routers checked at build time, middleware with typed tags and four stages, streaming, server-sent events, file serving, gzip, and outbound TCP and TLS. It runs on Apple silicon macOS and on arm64 and x86_64 Linux with musl.
- Integrations: `roxum-concurrency-limit`, `roxum-cookie`, `roxum-cors`, `roxum-http-client`, `roxum-normalize-path`, `roxum-postgres`, `roxum-proxy-headers`, `roxum-rate-limit`, `roxum-set-header`, `roxum-sse`, and `roxum-trace`.
