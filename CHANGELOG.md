# Changelog

Changes to the roxum platform and its integrations, newest first. The platform and each integration have their own versions; see [versioning](docs/design/versioning.md). An entry about an integration starts with its name.

## Unreleased

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
