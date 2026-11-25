# gRPC scope and milestones

Core 0.2 introduced finite Unary gRPC. Core 0.3 adds the three streaming
forms. For application setup, see the [service guide](../../integrations/roxum-grpc/README.md)
and [TLS proxy configuration](../guides/reverse-proxy.md#native-grpc-over-tls).

## Scope and responsibilities

Inbound TLS, outbound gRPC, gRPC-Web, reflection, compression, automatic retries,
and service discovery are outside this target. For WebSocket server support, see the [scope policy](../design/non-goals.md#features-excluded-unless-strong-demand-emerges).

| Layer | Responsibility |
|---|---|
| Zig host | HTTP/2 framing, header compression, flow control, scheduling, bounded resources, cancellation, deadlines and shutdown. No Protobuf types or gRPC status policy. |
| Core Roc API | HTTP metadata, incremental input/output, trailers and request-scoped execution controls. No socket pointers or stream IDs in the application API. |
| Protobuf library | Pure encoding and bounded decoding, independent of roxum and hosted effects. |
| Build-time generator | Schema descriptors to Roc codecs and optional service bindings; no runtime schema compiler. |
| gRPC integration | Envelopes, metadata, timeout parsing, status mapping and typed method dispatch. |
| Application | Business logic, authorization, persistence and deployment policy. |

These boundaries follow the [platform design](../design/platform-boundary.md).
Normal integration failures become gRPC statuses; host admission and transport
failures may remain HTTP errors or resets. Generic HTTP compression or keep-alive
middleware must not alter RPC framing. HTTP DATA and gRPC message boundaries differ.

## Milestones and evidence

| Capability | Design and acceptance |
|---|---|
| HTTP/2 transport | [Engine selection](http2-transport.md) and [finite listener acceptance](http2-finite-acceptance.md) cover TCP/Unix, ownership, cancellation, deadlines and drain. |
| Protobuf codecs and generator | [Design assessment](protobuf-codegen.md) and [distribution contract](../../libraries/roc-protobuf/DISTRIBUTION.md) define the supported schema subset and matched tool/library versions. |
| Typed Unary services | [Unary fixtures](../../tests/grpc-unary/README.md) cover independent clients, final status, deadlines and TLS proxy interoperability. |
| Typed streaming services | [0.3 acceptance](grpc-streaming-0.3.md) covers server-streaming, client-streaming, duplex execution and distribution. |
