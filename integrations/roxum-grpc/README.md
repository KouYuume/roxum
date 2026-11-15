# gRPC protocol foundation

This package provides finite Unary wire helpers using roxum's HTTP/2 capabilities.
It is the protocol foundation for the planned typed Unary integration, not a
complete RPC server API. Opt-in generated service bindings and finite typed Unary handlers are available.
Timeout installation is supported; final deadline status delivery and proxy/client
acceptance remain separate work. No new host effect or
Protobuf dependency is required by these byte-oriented helpers.

The contract follows [gRPC over HTTP/2](https://grpc.github.io/grpc/core/md_doc__p_r_o_t_o_c_o_l-_h_t_t_p2.html).

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

```sh
python3 tools/check.py --only test-grpc-wire
bash tools/linux/test.sh python3 tools/check.py --only test-grpc-wire
```

The group runs module expectations and independent grpcio and HTTP/2 clients on
TCP and Unix listeners across backend/allocator combinations. It checks exact
response bytes and final status, initial/duplicate/binary metadata, UTF-8 status
messages, split DATA, size/count boundaries and invalid envelopes/headers.
Deterministic arbitrary-byte and structured framing/Base64 corpora exercise the
new parsers against independent Python models. A valid call after failures
checks connection survival. The fixture supplies bytes without generated
service bindings; it is not the final Unary release acceptance test.

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
UNIMPLEMENTED). Service and method options, streaming RPCs, missing or invisible
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
See `tests/grpc-unary/app.roc` for runnable registration and handlers.
Verify with `python3 tools/check.py --only test-grpc-unary`.

## Timeout and cancellation

`GrpcTimeout.parse` accepts one to eight ASCII digits and the case-sensitive
units H/M/S/m/u/n. Zero expires immediately. Large valid durations saturate at
U64 nanoseconds. Duplicate, empty, signed, fractional or malformed fields are
INVALID_ARGUMENT; a missing field leaves the server execution cap unchanged.
The layer validates protocol headers before installing a duration through
`RequestExecution.limit_nanoseconds!`. The host anchors it at initial header
completion, so time spent queued or in earlier middleware is not added back.

Host expiry and client reset abandon suspended request execution and release
request resources. They cannot preempt arbitrary pure computation. A committed
response wins over later execution expiry; output still has its write timeout.

**Remaining release gate:** host expiry currently emits an HTTP/2 stream reset,
not a `grpc-status: 4` trailer. A client with its own matching deadline can report
DEADLINE_EXCEEDED locally; a raw timeout-header caller observes a reset (which
may map to CANCELLED). This is transport enforcement, not complete gRPC deadline
status delivery. A generic host expiry-response capability and integration status
mapping must be resolved before claiming the first Unary release complete.
