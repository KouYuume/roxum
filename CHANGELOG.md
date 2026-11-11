# Changelog

Changes to the roxum platform and its integrations, newest first. The platform and each integration have their own versions; see [versioning](docs/design/versioning.md). An entry about an integration starts with its name.

## Unreleased

### Breaking changes

- `Http.Version` includes `Http20`; exhaustive matches must handle the new variant. This represents HTTP/2 request metadata; production listeners still accept only HTTP/1.0 and HTTP/1.1.

- Listener settings use `Server.Endpoint.Tcp({ address, port })` or `Server.Endpoint.Unix({ path })`; request peers use `RemoteAddr.Tcp({ ip, port })` or `RemoteAddr.Unix`. Match on the transport before using IP-based policies.

- Application and metrics listener addresses now use `IpAddr.V4` / `IpAddr.V6` instead of `Server.Ipv4Address`. Import `pf.IpAddr` and replace `Server.Ipv4Address.(a, b, c, d)` with `IpAddr.V4((a, b, c, d))`.

### Added

- Internal HTTP/2 request input storage with per-stream header/body limits, a shared connection memory budget, and reset/disconnect cleanup. Production scheduler integration remains pending.

- Internal HTTP/2 initial-header mapping into Roc request metadata, including authority handling and split Cookie fields. Production HTTP/2 listener and scheduler integration remain pending.

- Filesystem Unix domain sockets for application and metrics listeners, with shared worker descriptors and identity-checked shutdown cleanup.
- roxum-proxy-headers: explicit `trust_unix` / `try_trust_unix` policies; ordinary CIDR trust rejects Unix forwarding headers.

- IPv6-only application and metrics listeners, preserving IPv6 peer addresses through request handling. IPv4 listener behavior is unchanged.

## 0.1.0

### Added

- The first release: a web server platform for Roc with typed handlers and extractors, routers checked at build time, middleware with typed tags and four stages, streaming, server-sent events, file serving, gzip, and outbound TCP and TLS. It runs on Apple silicon macOS and on arm64 and x86_64 Linux with musl.
- Integrations: `roxum-concurrency-limit`, `roxum-cookie`, `roxum-cors`, `roxum-http-client`, `roxum-normalize-path`, `roxum-postgres`, `roxum-proxy-headers`, `roxum-rate-limit`, `roxum-set-header`, `roxum-sse`, and `roxum-trace`.
