# gRPC server implementation plan

Status: milestone 1 in progress. Finite HTTP/2 listeners are implemented; gRPC support is not.
See the [transport decision and evidence](http2-transport.md). The responsibility
split is agreed; API names,
dependencies, and the detailed implementation below remain proposals until their
milestone's design checks pass. This document does not describe current support.

## Objective and scope

Enable an independently deployed roxum service to answer native gRPC clients.
The first usable milestone is a generated, typed Unary RPC service tested with an
independent client. Subsequent milestones add server, client, and bidirectional
streaming. Completion of Unary RPC must not be advertised as support for all RPC
forms.

Start with explicitly configured cleartext HTTP/2 using prior knowledge behind a
TLS-terminating proxy. The proxy must use HTTP/2 to reach roxum for native gRPC;
the existing HTTP/1.1 upstream configuration is insufficient. Keep HTTP/1.1 as
the default and retain the TCP/Unix endpoint distinction. Protocol selection is
separate from endpoint addressing; its public API is a milestone 0 decision.
Do not require HTTP/1.1 Upgrade negotiation for this first transport.

Inbound TLS, outbound gRPC clients, gRPC-Web, reflection, message compression,
automatic retries, and service discovery are outside the first release. They
can be added independently when required. WebSocket remains deferred until a
concrete use case or interoperability requirement justifies it; gRPC does not
depend on WebSocket support.

## Responsibilities

| Layer | Responsibility | Boundary |
|---|---|---|
| Zig host | HTTP/2 framing and header compression, connection and stream state, flow control, scheduling, resource limits, cancellation, deadlines, and shutdown | Own OS resources and enforce their lifetimes. No service descriptors, Protobuf types, or gRPC status policy. |
| Core Roc API | Typed access to HTTP metadata, body I/O, response completion with trailers, and request-scoped execution controls | Expose capabilities rather than socket pointers or HTTP/2 stream IDs. |
| Independent Protobuf library | Pure encoding and bounded decoding of supported Protobuf types | No dependency on roxum or hosted effects. |
| Build-time generator | Turn supported schema descriptors into Roc types/codecs and service bindings | Run before the application build; no schema compiler in the runtime host. |
| gRPC integration | Message envelopes, metadata conventions, timeout parsing, status mapping, method dispatch, and RPC APIs | Interpret gRPC using core HTTP capabilities and the Protobuf library. |
| Application | Business behavior, authorization, persistence, and deployment policy | Compose integration handlers with application services. |

The split follows the [platform boundary](../design/platform-boundary.md),
[public API layout](../design/public-api-layout.md), and
[execution model](../design/execution-model.md). An existing native library is
not by itself a reason to put pure application protocol logic in the host.

For a reply, the integration encodes a value, adds the gRPC message envelope,
writes HTTP body bytes, and supplies final metadata including `grpc-status`.
The host validates and transmits HTTP fields without interpreting that status.
HTTP DATA chunks and gRPC messages have independent boundaries; the integration
must handle both split and coalesced messages. See the
[gRPC wire protocol](https://grpc.github.io/grpc/core/md_doc__p_r_o_t_o_c_o_l-_h_t_t_p2.html).

## Current gaps and design checks

- `platform/host/http1/`, `connection.zig`, and `server.zig` implement HTTP/1.x
  framing and request execution. HTTP/2 needs a connection owner that can keep
  several independent request lifetimes alive. A stream failure must not reuse
  connection-wide cleanup that terminates unrelated RPCs.
- `Handler.streaming` in `platform/Handler.roc` consumes request chunks before
  its `done!` returns a reply. `Reply.stream` and `ResponseWriter` write a reply
  after dispatch. They do not establish a public full-duplex contract. Design
  and test that contract before committing to an RPC streaming API.
- Trailers need an explicit completion operation: final fields may only be
  known after body writes. Define header validation, completion exactly once,
  trailers-only replies, and failure after headers. Response trailers are
  required for the first gRPC service. Request-trailer access and HTTP/1.1 trailer
  support are separate extensions, not prerequisites to claim in this plan.
- Parse `grpc-timeout` in Roc and pass a bounded execution deadline to the host.
  Define a monotonic receipt-time anchor for the initial request headers and
  make elapsed time available to the integration. Apply the parsed timeout
  before waiting for the body; account for time already spent queued or in
  metadata processing rather than starting a fresh timeout at handler entry.
  An already-expired RPC must not begin application work. The exact timing API
  is a milestone 0 design decision, not a reason to parse gRPC headers in Zig.
  Distinguish the RPC deadline from idle/read/write timeouts and from configured
  server limits. Cancellation must release suspended I/O and request resources;
  it does not promise preemption of arbitrary Roc computation. Define observable
  outcomes for completion/deadline races. See the gRPC
  [deadline](https://grpc.io/docs/guides/deadlines/) and
  [cancellation](https://grpc.io/docs/guides/cancellation/) guides.
- Specify how middleware and host-generated failures interact with gRPC. Normal
  integration failures use gRPC statuses; HTTP admission failures and fatal
  transport failures may remain HTTP errors or stream resets. Do not add hidden
  gRPC-specific error rewriting in Zig. Authentication must run before dispatch,
  and generic HTTP body compression or keep-alive bytes must not alter RPC data.
- Record the policy for slow consumers, stream admission, header sizes, message
  sizes, decoded allocation, nesting, and queued writes. Set limits before
  allocating from untrusted lengths. A stopped consumer must not cause unbounded
  buffering or indefinitely prevent unrelated streams from progressing.

## Milestones and acceptance gates

Execute milestones in dependency order. Each may require several focused PRs;
do not combine the entire plan into a single implementation PR. Publish current
design contracts only when their implementation is accepted.

### 0. Prove the transport and lifetime design

Completed by the [isolated spike and transport decision](http2-transport.md).
The requirements below define its gate; production integration remains milestone 1.

Compare maintained HTTP/2 implementations usable from Zig against a custom
implementation. Assess license, dependency size, supported targets, incremental
I/O, allocator control, cancellation, and maintenance cost. Prefer reuse when it
fits, but record the actual choice and pin before introducing a dependency.
The host owns integration with the chosen engine; this does not require writing
the protocol engine from scratch.

Sketch the smallest protocol-selection, trailer-completion, deadline, and duplex
capabilities. Use [HTTP/2 RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html) as
the protocol baseline. Make stream ownership, connection ownership, and the
mapping to fibers explicit, including application initialization and worker drain.

Gate: a disposable interoperability spike runs two exchanges on one connection,
cancels one without killing the other, completes a response with trailers, and
demonstrates a reply before request EOF. Use an independent HTTP/2 client. The
spike is evidence for architecture, not a supported API or a production server.
Record unresolved constraints before advancing; revise the design if the current
execution model cannot express the required lifetimes safely.

### 1. Build core HTTP/2 capabilities

In progress: [host dependency, internal engine, and nonblocking connection owner](../design/http2-engine.md).
Opt-in TCP/Unix HTTP/2 listeners now dispatch finite requests through the production
worker scheduler. Generic trailers, metadata-time deadlines and the fixed-byte gRPC
probe remain required before this milestone is complete.

Implement explicit opt-in HTTP/2 listeners and bounded stream execution, generic
response trailers, deadlines, and cancellation. Keep gRPC schemas and status
codes out of core. Preserve the existing HTTP/1.1 behavior and endpoint API.
Include connection-level shutdown and per-stream cleanup, memory accounting,
admission, logs, and metrics; distinguish requests/streams from connections.

Gate: ordinary HTTP/2 requests and a fixed-byte gRPC interoperability probe work
on TCP and Unix listeners. Verify slow readers, resets, partial input, invalid
frames/headers, resource exhaustion, and draining with concurrent streams. The
probe must validate the response body and final status, not merely HTTP 200.
HTTP/1.1 and existing integrations retain their contract tests. No public gRPC
support claim is made yet.

### 2. Build reusable Protobuf support and code generation

First inventory reusable Roc codecs and generators. If none meets the required
contracts, implement a pure library under `libraries/` and an independent
build-time generator. Prefer consuming `protoc` descriptors or its
[plugin interface](https://protobuf.dev/reference/cpp/api-docs/google.protobuf.compiler.plugin.pb/)
over implementing a second `.proto` parser.

Define and document the initial schema support matrix, starting with proto3:
scalar values, messages, repeated/packed fields, maps, enums, field presence,
and oneof semantics. Explicitly reject unsupported schema features during
generation. Define unknown-field handling and decoder resource bounds. Keep
codec generation independent of optional roxum service bindings.

Gate: generated Roc code compiles with the pinned compiler; independent Protobuf
implementations exchange values in both directions. Test malformed/truncated
input, length and integer boundaries, unknown fields, and supported presence
semantics. Compare decoded values rather than requiring one canonical encoding.
See the [Protobuf encoding specification](https://protobuf.dev/programming-guides/encoding/).

### 3. Deliver the first usable Unary RPC integration

Add a separately versioned `roxum-grpc` integration using the core capabilities
and generated codecs. Provide typed service registration, exactly one request
and response message for successful Unary RPC, metadata, deadlines, and gRPC
status handling. Errors may complete without a response message, including
trailers-only responses.
Start with uncompressed messages and explicitly reject unsupported encodings.
Include a small runnable service and a reproducible independent client fixture;
the fixture must not require server reflection.

Gate: an independent generated client calls success and application-error paths,
checks trailers and trailers-only failures, and exercises unknown methods,
invalid metadata/messages, missing or extra Unary messages, cancellation,
deadline expiry, and limits. Include a delayed or partial request body and a
request queued past its deadline; neither may acquire a fresh timeout when the
handler starts, and expired queued calls must not invoke application work.
Another RPC on the same connection survives a
stream-local failure. Test through a proxy with downstream TLS and upstream
HTTP/2 as well as direct cleartext connections. Register package compatibility,
release metadata, examples, and checks using the existing integration workflow.

This is the first release target. Do not defer resource safety or cancellation
correctness to the later streaming milestones.

### 4. Add server-streaming RPC

Expose incremental response messages and final status through the integration.
Keep completion metadata distinct from body bytes and avoid retaining earlier
messages. Specify application failure after some messages have been sent.

Gate: an independent client observes messages before completion, receives the
final status, and can cancel a blocked writer without affecting another stream.
Measure bounded memory with a slow consumer and verify deadline and drain paths.

### 5. Add client-streaming and bidirectional RPC

Promote the duplex design proven in milestone 0 into a supported core capability
and typed integration API. The server must be able to send while request input
remains open. Define independent half-close, receive/send waits, finalization,
and cancellation without handles escaping their request lifetime. Do not emulate
bidirectional RPC by buffering the complete request first.

Gate: a client waits for the first server response before sending its next
message, proving interleaving. Exercise both half-close orders, blocked reads and
writes, deadlines, disconnects, and shutdown; verify resource return to baseline
and progress of unrelated streams. Enable and test each RPC form explicitly.

## Verification and delivery

Every implementation milestone includes meaningful negative tests and exact
boundary cases, as required by `AGENTS.md`. New parsing/state machines need
fuzz coverage. Keep independent-client interoperability tests separate from
internal round trips so shared encoder/decoder bugs cannot validate themselves.
Pin test-client and generator versions and retain reproducible fixtures.

For ABI, ownership, or execution changes, regenerate glue, rebuild host and Roc
sources together, and run the affected backend/allocator matrix on macOS and
Linux, ownership contracts, and semantic ABI checks. Build all supported targets;
state which architectures were executed rather than only cross-compiled. Run
the complete committed-tree suite before push or PR creation, following
[contributing](../contributing.md) and [toolchain](../toolchain.md).

Do not claim a throughput improvement from HTTP/2 support alone. Any comparative
performance work follows the existing benchmark protocol. During correctness
work, measure resource bounds and fairness without turning those diagnostics
into general performance claims.

Before each implementation milestone, resolve its API/dependency choices from
the spike and existing contracts. Escalate only decisions that change agreed
scope or require a new product tradeoff. No delivery dates or new public type
names are committed by this plan.
