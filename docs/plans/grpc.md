# gRPC scope and roadmap

Finite, uncompressed Unary RPC is implemented and its acceptance gates are complete.
Use the [integration API](../../integrations/roxum-grpc/README.md),
[greeting example](../../integrations/roxum-grpc/example/README.md), and
[distribution guide](../../integrations/roxum-grpc/DISTRIBUTION.md) for current behavior.
Publishing and release version selection remain maintainer operations.
Streaming RPCs below are proposals, not supported capabilities or delivery commitments.

## Scope and responsibilities

The first release target is a generated, typed Unary service usable by independent
native gRPC clients. Configure cleartext prior-knowledge HTTP/2 on TCP or Unix
behind a [TLS-terminating proxy with an HTTP/2 upstream](../guides/reverse-proxy.md#native-grpc-over-tls).
HTTP/1 remains the default. There is no automatic HTTP/1 Upgrade negotiation.

Inbound TLS, outbound gRPC, gRPC-Web, reflection, compression, automatic retries,
and service discovery are outside this target. WebSocket is independent and
remains deferred under the [scope policy](../design/non-goals.md).

| Layer | Responsibility |
|---|---|
| Zig host | HTTP/2 framing, header compression, flow control, scheduling, bounded resources, cancellation, deadlines and shutdown. No Protobuf types or gRPC status policy. |
| Core Roc API | HTTP metadata, finite body access, trailers and request-scoped execution controls. No socket pointers or stream IDs in the application API. |
| Protobuf library | Pure encoding and bounded decoding, independent of roxum and hosted effects. |
| Build-time generator | Schema descriptors to Roc codecs and optional service bindings; no runtime schema compiler. |
| gRPC integration | Envelopes, metadata, timeout parsing, status mapping and typed method dispatch. |
| Application | Business logic, authorization, persistence and deployment policy. |

These boundaries follow the [platform design](../design/platform-boundary.md).
Normal integration failures become gRPC statuses; host admission and transport
failures may remain HTTP errors or resets. Generic HTTP compression or keep-alive
middleware must not alter RPC framing. HTTP DATA and gRPC message boundaries differ.

## Completed milestones and acceptance gates

| Milestone | Evidence and boundary |
|---|---|
| 0. Transport feasibility | [Decision and isolated spike](http2-transport.md): independent streams, cancellation, trailers and output before request EOF. The spike does not establish a public duplex API. |
| 1. Finite HTTP/2 core | [Acceptance matrix](http2-finite-acceptance.md): production TCP/Unix listeners, ownership, resource bounds, backpressure, cancellation, metadata-time deadlines and concurrent-stream drain. |
| 2. Protobuf codecs and generator | [Assessment](protobuf-codegen.md) and [distribution contract](../../libraries/roc-protobuf/DISTRIBUTION.md): documented proto3 subset, independent interoperability, malformed input and resource boundaries, matched tools/library and standalone artifacts. |
| 3. Unary integration | The checks below cover generated services, protocol errors, deadlines, TLS proxying and release-artifact use. |

| Check | Unary acceptance evidence |
|---|---|
| `test-grpc-wire` | Exact envelopes, initial/duplicate/binary metadata, status encoding, malformed and oversized input, missing/extra messages, parser corpora and connection survival. |
| `test-grpc-unary` | Generated independent client; successful and rejected calls on direct TCP/Unix and nginx TLS-to-HTTP/2 upstreams. Raw HTTP/2 assertions require final deadline status, not a client-local timeout or reset. Partial input and queued expiry must not restart budgets or invoke expired work; cancelled handlers must not resume. |
| `test-grpc-example` | Runnable greeting service and generated client across all compiler backends and allocators. |
| `test-m13a` | Release metadata/hashes, extracted generator, fresh URL imports of platform/gRPC/wire packages, and RPC calls outside the checkout in all three backends. |

Finite errors can return no response message. The host currently sends initial
headers and a final trailer block, not a single-HEADERS trailers-only response.
Deadline status delivery requires registration before expiry; cancellation and
I/O limits can still prevent delivery. See the integration contract for exact
[timeout behavior](../../integrations/roxum-grpc/README.md#timeout-and-cancellation).

## Remaining milestones

### 4. Add server-streaming RPC

Provide incremental response messages and terminal metadata without retaining
previous messages. Define failure after headers or after some messages have been
sent, and exactly-once completion. Finite trailers alone are not this capability.

Gate: an independent client receives messages before completion and then the
final status; cancellation of a blocked writer preserves another stream. Verify
bounded memory with slow consumers, deadlines, drain and resource cleanup.

### 5. Add client-streaming and bidirectional RPC

`Handler.streaming` and `Reply.stream` do not establish a public full-duplex API.
Design request-scoped incremental reads/writes, receive-credit accounting,
aggregate backpressure and independent half-closes before exposing streaming RPCs.
Keep connection and stream credit separate enough for peers to progress, and bound
queued bytes, decoded allocations, nesting and message sizes before allocation.
Request-trailer access and HTTP/1 trailers are separate extensions.

Gate: a client waits for the first server response before sending its next
message, proving interleaving rather than whole-request buffering. Exercise both
half-close orders, blocked reads/writes, deadlines, disconnects and shutdown.
Require peer progress and resources returning to baseline. Enable and verify
each RPC form explicitly; the transport spike is not runtime acceptance.

## Verification policy

Use pinned independent clients and meaningful negative/boundary cases; shared
encoder/decoder round trips cannot establish interoperability. Fuzz new parsers
and state machines. ABI, ownership and execution changes require paired host/Roc
builds and the [toolchain verification matrix](../toolchain.md), including Linux.
Distinguish executed architectures from cross-compilation. Run the committed-tree
full suite before push or PR creation as required by [contributing](../contributing.md).

Correctness diagnostics do not establish throughput improvements. Comparative
claims require the [benchmark protocol](../../bench/m13/protocol.md).
