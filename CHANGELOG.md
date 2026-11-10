# Changelog

Changes to the roxum platform and its integrations, newest first. The platform and each integration have their own versions; see [versioning](docs/design/versioning.md). An entry about an integration starts with its name.

## Unreleased

### Breaking changes

- Application and metrics listener addresses now use `IpAddr.V4` / `IpAddr.V6` instead of `Server.Ipv4Address`. Import `pf.IpAddr` and replace `Server.Ipv4Address.(a, b, c, d)` with `IpAddr.V4((a, b, c, d))`.

### Added

- IPv6-only application and metrics listeners, preserving IPv6 peer addresses through request handling. IPv4 listener behavior is unchanged.

## 0.1.0

### Added

- The first release: a web server platform for Roc with typed handlers and extractors, routers checked at build time, middleware with typed tags and four stages, streaming, server-sent events, file serving, gzip, and outbound TCP and TLS. It runs on Apple silicon macOS and on arm64 and x86_64 Linux with musl.
- Integrations: `roxum-concurrency-limit`, `roxum-cookie`, `roxum-cors`, `roxum-http-client`, `roxum-normalize-path`, `roxum-postgres`, `roxum-proxy-headers`, `roxum-rate-limit`, `roxum-set-header`, `roxum-sse`, and `roxum-trace`.
