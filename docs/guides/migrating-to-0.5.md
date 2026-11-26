# Migrating from 0.4 to 0.5

Build applications with the pinned Roc `0.1.0-RC2` compiler and matching host
archives. Use the 0.5 release's `release.json` to update your app's platform
and integration URLs together. Each published integration embeds the platform
URL it was built against. For local builds, follow the
[toolchain setup](../toolchain.md).
The public Roc handler signatures, listener options and their defaults are
unchanged from 0.4.

## HTTP files

If you routed file requests to HTTP/1 upstreams, you can now serve known-length
files over HTTP/2, including single byte ranges and precompressed variants.
Keep an HTTP/1 upstream or use precompressed files if you rely on dynamic
gzip for files. Active file transfers share the process's writer limit with
other streamed responses. See [serving a directory](files.md#serving-a-directory).

## Server-sent events

An HTTP/2 route can now use `Sse.reply` with its default 15-second keep-alive
and graceful drain. If you disabled these options for HTTP/2 in 0.4, you can
remove those overrides. Choose `response_write_milliseconds` for the intended
stream lifetime. The default is 30 seconds, and sending events or keep-alives
does not extend the HTTP/2 deadline. HTTP/1 applies the timeout to
each write. Scope broker subscriptions to the callback so an idle disconnect
releases them. See [publishing from another request](streaming.md#publishing-from-another-request).

## gRPC

For services built from release bundles, regenerate bindings using the release’s generator
and the same platform, gRPC and wire package URLs as the app.
See the [gRPC distribution guide](../../integrations/roxum-grpc/DISTRIBUTION.md#build-a-service-outside-the-checkout).

Existing services can keep their handlers and service limits. For long-lived
streaming RPCs, configure both the service duration and the HTTP/2 write timeout.
The default server-streaming duration is five minutes, but it cannot extend
the 30-second default write deadline. A registered RPC deadline can produce
`DEADLINE_EXCEEDED`. A client reset abandons a suspended call and releases its
resources. See [timeout and cancellation](../../integrations/roxum-grpc/README.md#timeout-and-cancellation).
