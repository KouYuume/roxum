# gRPC integration

This package provides typed Unary, server-streaming and client-streaming handlers with opt-in
generated service bindings using roxum's HTTP/2 capabilities. Both streaming forms are part of the unreleased 0.3 work.
Bidirectional framing is available for manually registered routes. Generated routes
install deadlines before waiting for request bodies and register a final gRPC
status response on expiry. Independent generated clients and raw HTTP/2 checks
cover direct TCP/Unix listeners and nginx TLS termination; see
[Unary acceptance](../../tests/grpc-unary/README.md) and
[server-streaming acceptance](../../tests/grpc-streaming/README.md). A
[runnable greeting service](example/README.md) and
[distribution guide](DISTRIBUTION.md) cover generated clients and verified
release-artifact use outside the checkout. The byte-oriented wire helpers do
not require a Protobuf dependency.

The contract follows [gRPC over HTTP/2](https://grpc.github.io/grpc/core/md_doc__p_r_o_t_o_c_o_l-_h_t_t_p2.html).

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
and method names. Callback field names use `call_` plus the lowercase method
name and `!`; collisions are rejected. Existing router fallbacks continue to
handle unknown routes (the default HTTP 404 is mapped by gRPC clients to
UNIMPLEMENTED). Service and method options, bidirectional RPCs, missing or invisible
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

## Manual bidirectional routes

Register `GrpcDuplex.handler(decode, encode, callbacks, limits)` on a POST route
with `GrpcTimeout.streaming_layer(limits)`. Generated bidirectional bindings are
planned for 0.3. The handler accepts the same limits as server-streaming, with
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

[Production fixtures](../../tests/grpc-streaming/README.md) cover generated
clients, raw framing, TLS proxies, stalled readers, repeated cancellation and
bounded memory. The [example](example/README.md) exercises both Unary and
server-streaming, including from extracted distribution artifacts.

## Timeout and cancellation
`GrpcTimeout.parse` accepts one to eight ASCII digits and the case-sensitive
units H/M/S/m/u/n. Zero expires immediately. Large valid durations saturate at
U64 nanoseconds. Duplicate, empty, signed, fractional or malformed fields are
INVALID_ARGUMENT; a missing field leaves the server execution cap unchanged.
The layer validates protocol headers before installing a duration through
`RequestExecution.limit_with_response!`, registering a bounded HTTP 200 response
with `grpc-status: 4` and `grpc-message: deadline%20exceeded`. The host anchors
the duration at initial header completion, so time spent queued or in earlier middleware is not added back.

Host expiry and client reset abandon suspended request execution and release
request resources. They cannot preempt arbitrary pure computation. A committed
response wins over later execution expiry; output still has its write timeout.

Expiry sends the registered DEADLINE_EXCEEDED response independently of request
cleanup, including while the request body is incomplete. Response delivery remains
subject to connection memory limits, peer cancellation, and I/O timeouts. A server
execution cap that expires before the layer runs still resets the stream because
no integration response has been registered. A client reset never triggers this
response. See [reverse proxy deployment](../../docs/guides/reverse-proxy.md#native-grpc-over-tls)
for the tested TLS-termination configuration.

## Framing
`GrpcFrame.decode_unary(bytes, maximum)` requires exactly one complete,
uncompressed message. The five-byte prefix contains a flag followed by a
big-endian U32 payload length. Empty payloads still require the prefix. Missing,
truncated, invalid-flag, compressed, oversized and trailing-byte inputs return
typed errors. Length is checked before extracting payload bytes. All trailing
bytes, whether another full envelope or incomplete data, are `ExtraMessage`.
`encode` bounds payload length against both the caller's limit and U32.

These helpers consume a finite body already assembled by the host; HTTP DATA
boundaries have no significance. They do not expose a streaming parser or bound
body buffering before handler entry. Configure the server's finite request and
response byte limits as well as the codec limits.

## Metadata
`GrpcMetadata.Entry` is `Text(name, value)` or `Binary(name, bytes)`. Names are
lowercase ASCII letters, digits, `_`, `-`, and `.`, and binary names include the
`-bin` suffix. Ordered lists preserve duplicate values. The decoder splits
comma-joined binary values before decoding and accepts standard padded or
unpadded Base64. Padding placement and unused bits must be canonical; outgoing
Base64 omits padding. Empty binary values are supported.

Incoming ASCII values outside printable ASCII are dropped, as permitted by the
gRPC protocol for HTTP-valid values; surrounding space is removed. Outgoing
text must be printable ASCII and cannot contain CR/LF; surrounding spaces are
removed before byte accounting and HTTP/2 encoding. Protocol fields,
`grpc-*`, and HTTP transport fields are excluded from custom input metadata and
rejected as custom output metadata. `grpc-status-details-bin` is not exposed.
Authentication fields such as `authorization` may be read as request metadata,
but the host forbids them in trailers; response helpers reject them there.
Select which request values to return instead of blindly reflecting credentials.

Limits default to 8,192 bytes and 62 custom entries. Byte accounting is the sum
of name bytes, on-wire value bytes, and 32 bytes per field. Input accounting
includes protocol fields even though they are not returned. Each decoded binary
segment consumes an entry, including empty segments. Output limits are applied
separately to custom initial and trailing metadata; fixed protocol fields and
status text have separate overhead. The response helpers cap custom fields at
62 even if the caller asks for more, reserving two of the host's 64 field slots.
Host header byte limits still apply; configure limits with protocol overhead
and middleware additions in mind. These are logical bounds, not exact allocator
or CPU quotas.

## Request and response helpers
`GrpcWire.request_metadata(version, method, headers, limits)` checks HTTP/2,
POST, a single supported content type, and `te: trailers`. Media types are
case-insensitive; `application/grpc` and `application/grpc+proto` are accepted,
with optional media parameters. JSON and gRPC-Web are not supported. Absent
encoding or `identity` is accepted; message and HTTP body compression are
rejected. Duplicate or empty singleton protocol fields are rejected.

This call does not parse or apply `grpc-timeout`. It does not authenticate,
route, or decode Protobuf. The Unary route layer must run metadata/deadline
handling before waiting for the body; calling these finite helpers after body
assembly does not provide that guarantee.

`GrpcWire.success(message, initial, trailing, limits)` creates a finite HTTP 200
reply with `application/grpc+proto`, one envelope, initial metadata, and final
`grpc-status: 0`. `GrpcWire.failure(code, message, trailing, limits)` requires a
non-OK code and returns HTTP 200 with no message body and final status/message
fields. The current host emits initial headers followed by a trailer block for
empty-body failures; this is not a single-block trailers-only API.

`GrpcStatus.Code` covers all 17 standard codes. Status messages encode UTF-8
bytes using gRPC percent-encoding, escaping spaces, `%`, and nonprintable/non-ASCII bytes. Escaping spaces also
preserves leading/trailing spaces without invalid HTTP/2 field whitespace.
The caller bounds the encoded message size. Response construction errors remain
typed; applications must handle them before returning a reply.

`reject_request` maps media-type failures to HTTP 415, wrong HTTP version to
400, wrong method to 405, unsupported encoding to gRPC UNIMPLEMENTED, metadata
limits to RESOURCE_EXHAUSTED, and malformed metadata to INVALID_ARGUMENT.
`reject_frame` maps compression to UNIMPLEMENTED, size to RESOURCE_EXHAUSTED,
and missing/truncated/invalid/extra envelopes to INVALID_ARGUMENT. These mappings
do not rewrite host admission failures or transport resets. HTTP compression or
keep-alive middleware must not alter gRPC response bytes.

## Verification
Run a group with `python3 tools/check.py --only <group>`; prefix the command with
`bash tools/linux/test.sh` to run it on Linux.

| Group | Coverage |
|---|---|
| `test-grpc-example` | Runnable generated greeting service across backends and allocators. |
| `test-grpc-wire` | Finite framing/metadata helpers, independent grpcio and HTTP/2 clients, boundary and invalid inputs, parser corpora against Python models, and connection survival. |
| `test-grpc-unary` | [Generated-client acceptance](../../tests/grpc-unary/README.md), including deadlines, cancellation and TLS proxy deployment. |
| `test-m13a` | [Release-artifact consumer](DISTRIBUTION.md), rebuilt outside the checkout. |
