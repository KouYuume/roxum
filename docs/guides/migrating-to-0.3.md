# Migrating from 0.2 to 0.3

Keep the [0.2 compiler and Zig pins](../toolchain.md). Rebuild with the 0.3
platform sources and host archives together. For URL imports, use the platform
and integration URLs from the same `release.json`, including in generated services.

| Package | Version | Application action |
|---|---|---|
| roxum | 0.3.0 | Review HTTP/2 streaming handlers and response completion below. |
| roxum-grpc | 0.2.0 | Use the bundle targeting core `^0.3`. |
| roc-protobuf and protoc-gen-roc | 0.1.1 | Update the pair and regenerate bindings from the schema. |
| Other integrations | Existing package versions | Update bundle URLs to the builds targeting core `^0.3`. |

## HTTP applications

HTTP/1 remains the default. Ordinary handlers still receive complete bodies.
Code that matches exhaustively on `Handler` variants must handle `Duplex`.
On HTTP/2, `Handler.streaming` receives chunks before EOF. In 0.2,
`maximum_body_bytes` capped these requests even when streamed reads were
unlimited. In 0.3 it caps whole-body reads. To keep the old upload ceiling,
set `maximum_streamed_body_bytes: Server.BodyLimit.Bytes(n)` to the previous
byte limit and review route overrides from `BodyLimit.streamed`. The default is
`Unlimited`.

The HTTP/2 request-body deadline
runs from metadata completion and includes time spent in callbacks. Choose a
deadline that covers the complete upload. Reset, timeout and disconnect abandon
suspended work. Keep cleanup of external resources within the request lifetime.

A `Reply.stream` producer should return `Ok({})` for a successful end.
Returning `Err(StreamClosed)` aborts unfinished output. On HTTP/2 the write
timeout covers the response as a whole. Complete required application I/O before
calling `ResponseWriter.finish!` with terminal trailers. See the
[streaming guide](streaming.md) for writer options and protocol limits.

## gRPC services

Unary-only generated registrations keep their handler and limits shape. When
adding a streaming method to a Unary service, regenerate its bindings and pass
`{ unary, streaming }` limits to `register`. The streaming configuration bounds
message size, message count, cumulative payload and duration. See the
[greeting service](../../integrations/roxum-grpc/example/README.md) for all four
method forms and the [distribution guide](../../integrations/roxum-grpc/DISTRIBUTION.md)
for the generator and URL imports.

## API comparison

The pinned compiler's `roc bump` cannot extract the published 0.2 platform API:
`Config.load!` exposes a type from the bundled local `roc-toml` dependency.
Giving the identical TOML sources a shared versioned URL in temporary copies
still leaves an unexposed `RequestDecoder.Request` in the old public API.
The core minor bump reflects the new handler variant, input limits and stream
completion changes above. The gRPC comparison uses the candidate platform's
versioned URL because the integration exposes platform types. The standalone
Protobuf wire package exposes no platform types.
