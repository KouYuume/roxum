# Migrating from 0.1 to 0.2

0.2 adds IPv6 and Unix listeners, opt-in finite HTTP/2, and uncompressed Unary
gRPC. HTTP/1 remains the default. Existing HTTP/1 streaming, SSE and file routes
should stay on HTTP/1; HTTP/2 does not support streamed responses or streaming RPCs.

## Compiler and packages

Use Roc `9e85de7aba79eaeb8ca589ab6a1ea581274c8930` and Zig 0.17.1 as described in
[toolchain setup](../toolchain.md). Rebuild applications against the matching host
and platform sources. Old host archives are not compatible with the new hosted ABI.
For URL imports, take platform and integration URLs from the same 0.2 release's
`release.json`; updating only the platform URL leaves different platform identities.

| Package | Version in this release | Scope |
|---|---|---|
| roxum platform | 0.2.0 | Breaking public types and compiler update. |
| roxum-proxy-headers | 0.2.0 | Public request types carry TCP/Unix peers; Unix forwarding trust is explicit. |
| roxum-grpc | 0.1.0 | First release, finite uncompressed Unary services. |
| roc-protobuf / protoc-gen-roc | 0.1.0 / 0.1.0 | First matched library/generator release. |
| Other existing integrations | 0.1.0 | Behavior unchanged; the new bundles target core `^0.2`. |

Integration versions are independent of core. An unchanged version number does
not make a bundle from the 0.1 release interchangeable with one from 0.2.

## Listener settings

Replace `ListenOptions.address` and `port` with one `endpoint`. Import `pf.IpAddr`
and replace `Server.Ipv4Address` with `IpAddr.V4`:

```roc
# 0.1 fields inside listen
address: Server.Ipv4Address.(127, 0, 0, 1),
port: 8080,

# 0.2 replacement
endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 8080 }),
```

Metrics use the same endpoint type:

```roc
metrics: Server.Metrics.Listen(Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: 9090 })),
```

Keep existing `timeouts`, `limits`, threads and process settings. `protocol` may
be omitted to retain HTTP/1. See [listener endpoints](deployment.md#listener-endpoints)
for IPv6-only and filesystem Unix socket constraints.

## Peer addresses and forwarding policy

`RemoteAddr` is now `Tcp({ ip, port })` or `Unix`. Replace direct `.ip` / `.port`
access with a match and choose an explicit policy for Unix peers. For example,
a rate-limit key can use the IP on TCP and a shared key for local clients:

```roc
key = match head.remote_addr {
    Tcp({ ip, .. }) => RateLimit.client_ip(ip)
    Unix => "unix"
}
```

Unix peers have no synthetic IP or port. `ProxyHeaders.trust` does not trust them;
use `trust_unix` only when socket-directory access is restricted to trusted peers.
See [proxy headers](../../integrations/roxum-proxy-headers/README.md).

## Exhaustive matches and response construction

Add `Http20` to exhaustive `Http.Version` matches and `WithTrailers` to exhaustive
`Reply` matches. Prefer reply constructors and conversion helpers when custom code
does not need to inspect every variant. `Http.Response.trailers` defaults to `[]`,
so ordinary record construction can omit it. Forward the field when rebuilding a
response that may carry trailers; nonempty trailers are rejected on HTTP/1 and on
streamed/file responses. See [finite HTTP/2 trailers](responses.md#finite-http2-trailers).

The assemblers returned by `PathSegment.from_interpolation` and
`QueryValue.from_interpolation` now accept `Iter(Str)`. Direct callers passing a
list must convert it with `List.iter`. Typed string interpolation syntax is unchanged.

## Opting into Unary gRPC

Follow the [greeting example](../../integrations/roxum-grpc/example/README.md) or
[distribution guide](../../integrations/roxum-grpc/DISTRIBUTION.md). Enable
`Server.Protocol.Http2` on that listener and use a TLS-terminating proxy with an
HTTP/2 upstream. Generated service registration installs timeout handling before
body reception. Streaming RPCs, compressed messages, reflection and gRPC-Web are
outside this release's supported scope.

## API comparison limits

The published 0.1.0 platform targets Roc `262206271cf05db948eef2b96fae88a1aca07b19`.
`roc bump --old <0.1.0 platform URL> --old-version 0.1.0 --expect 0.2.0 platform/main.roc`
cannot compare it with this release: the old interpolation annotations fail on
the new compiler. The proxy-headers comparison fails through that same dependency.
A temporary source copy adapting only those two annotations also cannot establish
a complete comparison because `roc bump` rejects exposed types from local package
dependencies. Neither attempt counts as a successful API compatibility check.

The migration requirements above come from reviewing public source changes against
`v0.1.0`, including `platform/main.roc`'s application/host contracts. The known
breaking changes require the 0.2 minor bump independently of that tool limitation.
