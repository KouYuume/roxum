# Migrating from 0.3 to 0.4

Use the platform and integration bundle URLs from the same 0.4 release.
Integration package sources and versions are unchanged from 0.3. Their new
bundles target core `^0.4`. The pinned Roc compiler, Zig version and
standalone Protobuf wire library and generator are unchanged.

## Listener configuration

Update exhaustive matches on `Server.Protocol` to handle `Tls(options)`.
Existing HTTP/1.1, cleartext HTTP/2, Unix socket and reverse-proxy configurations
keep their previous behavior. Rebuild local apps with the matching platform
sources and host archives.

To terminate TLS in roxum, select `Server.Protocol.Tls` on a TCP listener.
Provide paths to the leaf-first certificate chain and matching private key.
The [deployment guide](deployment.md#inbound-tls) covers protocol negotiation,
handshake limits and credential rotation. For a generated gRPC service, see
the [client and listener example](../../integrations/roxum-grpc/example/README.md).
