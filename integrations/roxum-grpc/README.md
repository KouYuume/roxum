# gRPC integration

Register typed gRPC services on a roxum HTTP/2 listener. The
[greeting example](example/README.md) demonstrates all four RPC forms. For
URL imports and the matched generator, follow the [distribution guide](DISTRIBUTION.md).
For byte-level helpers, metadata restrictions and protocol error mappings, see
the [wire reference](WIRE.md).

All four method forms copy each request payload into an 8 MiB decoder heap
before calling the Protobuf codec. The input and fresh decode allocations
share this limit. Heap admission, input-copy or codec allocation failure returns
`RESOURCE_EXHAUSTED`. A bidirectional RPC completes any partially written
outbound message before sending the error trailers. Delivery remains subject
to cancellation, deadlines and transport capacity. Codec validation errors return `INVALID_ARGUMENT`.

## Typed Unary services
Generate codecs alone with the existing `wire=<path>` option. To also generate
roxum service modules, use `wire=<path>,grpc=<integration path>,pf=<platform path>`
with protoc-gen-roc. All paths are relative to the generated package root.
The application and generated package must use the same platform identity.

A service `Greeter` generates `GreeterService.register(router, handlers, limits,
codec_limits)`. Its `Greet` method requires a typed `call_greet!` callback receiving
application model, decoded request, and metadata. The callback returns
`Try(GrpcUnary.Response(Output), GrpcUnary.Failure)`. `GrpcUnary.response(value)`
and `GrpcUnary.failure(code, message)` construct the common cases; response
records also support initial and trailing metadata.

Registration adds exact POST routes using the original fully qualified service
and method names. Unary and one-directional callback field names use `call_` plus the lowercase method
name and `!`; collisions are rejected. Existing router fallbacks continue to
handle unknown routes (the default HTTP 404 is mapped by gRPC clients to
UNIMPLEMENTED). Service and method options, missing or invisible
message types, and module/binding name collisions fail generation atomically.
This includes `Handlers`, the generated callback record type.
Codec-only generation retains its platform-free package and ignores services.

`GrpcUnary.Limits` separates request/response payload bytes, encoded status bytes,
and metadata limits. Generated codec callbacks also enforce `ProtobufWire.Limits`.
Malformed input is INVALID_ARGUMENT; oversized envelopes are RESOURCE_EXHAUSTED.
Response encoding errors, invalid application status or output metadata become
INTERNAL without exposing codec diagnostics. Application failures return `Err`
to preserve the platform middleware rejection path.

These handlers run after finite body assembly. Generated registration installs
`GrpcTimeout.layer` before body reception. Manual `GrpcUnary.handler` users must
attach that layer themselves; the handler alone does not install deadlines.
Start with the [greeting example](example/README.md) for registration and handlers.

## Typed bidirectional services

For `Converse(stream Greeting) returns (stream ReplyText)`, supply a
`duplex_converse` record to the generated service registration. Each bidirectional
method has its own application state type, inferred from its callbacks. Registration
installs the streaming deadline layer and uses the same limits as server-streaming, with
independent message and payload budgets in each direction.

- `begin!(model, metadata)` returns the initial application state and response metadata.
- `receive!(state, input)` receives each decoded `Message(value)` and clean `End`,
  even while output is stalled. Return the updated state or a gRPC failure.
- `next!(state)` selects `Read`, `Send(value, next_state)`, or `Finish(trailing)`.
  After `Read`, the next output decision waits for a decoded message or clean EOF.
  After input ends, send remaining messages or finish. The integration keeps one
  encoded reply pending and requests another decision after accepting it.
  Application-owned queues must be bounded by the service.

Input errors after headers produce a terminal status. If part of an envelope has
already been accepted, the handler finishes that envelope before sending the
error trailers. On execution expiry the host abandons the handler and drains
already accepted DATA before sending deadline trailers if delivery is possible.
A message whose remaining bytes were still in the handler can therefore end
mid-envelope. Transport cancellation can also prevent trailer delivery.

## Typed client-streaming services

For `Submit(stream Input) returns (Output)`, the generated callback receives
the model and request metadata. Return `Ok(GrpcClientStream.consume(initial_state,
step!, finish!))` to accept input, or a `GrpcUnary.Failure` to reject the call.
Each complete message invokes `step!(state, input)`, which returns the next
state or an application failure. Clean end of input invokes `finish!(state)`
once, including for an empty stream. Return a `GrpcUnary.Response` from that
callback to send one message and final status.

Streaming registration uses `GrpcServerStream.Limits` for both directions.
On a client-streaming route, `messages` and `payload_bytes` bound the request
sequence, `request_bytes` bounds each input, and `response_bytes` bounds the
single output. The HTTP streamed-body limit counts all bytes including envelope
prefixes and can reject a request first. The body timeout is also absolute from
initial metadata. The integration checks declared lengths before buffering payloads.
Partial envelopes at EOF and invalid Protobuf messages yield INVALID_ARGUMENT.
Application state can retain input explicitly. The [upload fixture](../../tests/grpc-streaming/app.roc)
shows a running sum that only retains a counter.

## Typed server-streaming services

A method returning `stream Output` generates a callback returning
`Try(GrpcServerStream.Response(Output), GrpcUnary.Failure)`. Construct the response
with `GrpcServerStream.response(state, step!)`. Each step returns
`Ok(Next(message, next_state))`, `Ok(Done(trailing_metadata))`, or
`Err(GrpcUnary.failure(code, message))`. The response record also accepts initial
metadata. The integration pulls and sends one encoded message at a time; callers
do not receive a raw transport writer or need to choose when to finish.

```roc
watch! = |_model, Request.(request), _metadata| Ok(
    GrpcServerStream.response(0.U32, |index| {
        if index == request.count { return Ok(Done([])) }
        Ok(Next(Update.{ sequence: index, text: "item" }, index + 1))
    }),
)
```

Server-streaming-only registration takes `GrpcServerStream.Limits`; a service
mixing Unary and streaming methods takes `{ unary, streaming }` limits. Unary-only
registration is unchanged. Generated codecs still use the supplied
`ProtobufWire.Limits`. Request input remains exactly one finite message.

`GrpcServerStream.defaults` permits 2 MiB request and response payloads, 65,536
output messages, 64 MiB cumulative output payload (excluding envelope prefixes),
and five minutes from initial metadata. Override the duration per service;
client deadlines and server execution caps can only shorten it. Also configure
`Server.Timeouts.response_write_milliseconds` for the intended stream lifetime:
it is an absolute output deadline, and the integration duration cannot extend it.
Proxy I/O timeouts remain independent. Custom metadata
and encoded status bounds use the same rules as Unary. Logical limits do not
account for application-owned state: a producer that retains history retains it
intentionally. Message-count exhaustion is detected when the producer supplies
the first excess message; it is not encoded or sent.

Normal exhaustion sends status OK even for zero messages. An application failure
after output sends its status after earlier messages; invalid status/metadata or
encoding failures become INTERNAL. Count and cumulative-payload limits send
RESOURCE_EXHAUSTED. The callback itself can suspend; cancellation abandons it.
Generic compression and keep-alive middleware must not alter RPC output.

Generated registration installs a finite DEADLINE_EXCEEDED response before body
waits, then the handler replaces it with copied expiry trailers before streamed
output. Expiry after headers drains accepted DATA before status 4, subject to
write timeout and cancellation. Expiry between trailer registration and initial
headers can reset the stream. Manual handler users must install
`GrpcTimeout.streaming_layer(limits)` themselves for pre-body duration enforcement.
The integration owns final completion; required I/O belongs in producer steps,
not after the terminal status.

## Timeout and cancellation
`GrpcTimeout.parse` accepts one to eight ASCII digits and the case-sensitive
units H/M/S/m/u/n. Zero expires immediately. Large valid durations saturate at
U64 nanoseconds. Duplicate, empty, signed, fractional or malformed fields are
INVALID_ARGUMENT; a missing field leaves Unary calls under the server execution cap. Streaming calls also have a service duration limit.
The layer validates protocol headers before installing a duration through
`RequestExecution.limit_with_response!`, registering a bounded HTTP 200 response
with `grpc-status: 4` and `grpc-message: deadline%20exceeded`. The host anchors
the duration at initial header completion, so time spent queued or in earlier middleware is not added back.

Host expiry and client reset abandon suspended request execution and release
request resources. They cannot preempt arbitrary pure computation. A committed
finite response wins over later execution expiry; output still has its write timeout.

Expiry sends the registered DEADLINE_EXCEEDED response independently of request
cleanup, including while the request body is incomplete. Response delivery remains
subject to connection memory limits, peer cancellation, and I/O timeouts. A server
execution cap that expires before the layer runs still resets the stream because
no integration response has been registered. A client reset never triggers this
response.

On the 0.4 development branch, configure a [TCP TLS listener](../../docs/guides/deployment.md#inbound-tls-on-the-04-development-branch)
to serve native gRPC directly. Clients trust the server certificate and negotiate
`h2` via ALPN. For TLS termination at nginx, see [reverse proxy deployment](../../docs/guides/reverse-proxy.md#native-grpc-over-tls).

## Verification
Run a group with `python3 tools/check.py --only <group>`; prefix the command with
`bash tools/linux/test.sh` to run it on Linux.

| Group | Coverage |
|---|---|
| `test-grpc-example` | Generated greeting service on dev and speed with both allocators. |
| `test-grpc-wire` | Finite framing/metadata helpers, independent grpcio and HTTP/2 clients, boundary and invalid inputs, parser corpora against Python models, and connection survival. |
| `test-grpc-unary` | [Generated-client acceptance](../../tests/grpc-unary/README.md), including deadlines, cancellation and TLS proxy deployment. |
| `test-grpc-streaming` | [Streaming acceptance](../../tests/grpc-streaming/README.md), including backpressure, half-close, cancellation, bounded memory and shutdown. |
| `test-m13a` | [Release-artifact consumer](DISTRIBUTION.md), rebuilt outside the checkout. |
