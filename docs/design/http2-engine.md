# Internal HTTP/2 engine

This document defines the HTTP/2 host's ownership, resource bounds, and
execution contracts. HTTP/1 remains the default; TCP and Unix listeners opt into
cleartext HTTP/2. For configuration, see [deployment](../guides/deployment.md#opt-in-http2);
for supported RPC behavior, see the [gRPC integration](../../integrations/roxum-grpc/README.md).

For the copying and cleanup rules of completed requests and responses, see the
[finite adapters](http2-finite.md). For incremental input/output and duplex
execution, see the [streaming contract](http2-streaming.md).

## Dependency and replacement boundary

`build.zig.zon` pins the upstream source package and its Zig content hash.
`tools/nghttp2-build.zig` compiles only the 26 protocol-library C sources and
uses the pinned Zig compiler to generate bindings in the build cache. No system
nghttp2, CMake, TLS library, or additional language toolchain is required. The
library is included in `libhost.a` for all three supported targets, including
tracking-allocator builds. Release bundles include `platform/NGHTTP2-LICENSE`.
The expanded platform bundle budget is 13,000,000 bytes, including all supported
host targets and their runtime libraries.

Only the build helper and engine adapter name nghttp2 APIs. The adapter's public
internal types use Zig slices and stream identities; no C pointers, callback
types, or generated declarations are part of the public Roc API. This keeps a
future engine replacement local without creating a general plugin framework.

The [transport decision](../plans/http2-transport.md) records engine selection
and replacement criteria. Review upgrades together with the source list, version
header, package hash, license, and independent-client checks.

## Serialized ownership and I/O

An `Engine` has a stable address until `destroy`. One owner calls its methods;
concurrent use is forbidden. A reentrant call from an observer is rejected.
Observers copy or queue borrowed headers/data and stream notifications; they
must not run application code, block, retain the borrowed slices, or destroy the
engine. A close notification invalidates the stream identity for that engine.
Destroying the engine releases all its resources without notifying observers;
the connection owner must separately cancel its request lifetimes.

`headers_complete` optionally notifies the owner after validated initial metadata,
before request EOF. It is not emitted for trailers or rejected initial headers.
The notification runs inside the engine callback batch: it may record an admission
or deadline anchor, but must not execute application code.

`receive` consumes arbitrary input fragments. `output` returns an engine-owned
serialized buffer. The caller acknowledges only bytes actually written using
`consumeOutput`; repeated `output` calls preserve the unsent suffix. No socket,
poller, fiber, or Roc arena is owned by this adapter.

The initial response operation copies a finite body and validates final status
and response headers. Only one response may be submitted per live stream.
An explicit Content-Length must be a single decimal field fitting in `u64`;
ordinary responses require it to match the body length. It is forbidden on 204
and must be zero on 205. HEAD and 304 may carry representation length metadata;
the caller is responsible for its accuracy because that representation is not
necessarily supplied to this adapter.
The DATA provider marks EOF on its last nonempty read, so completion does not
require an extra byte of flow-control credit. Reset/closure releases the copied
body; destroy also releases responses retained by slow readers.

## Nonblocking connection owner

`Owner` owns one nonblocking accepted socket and its engine. Initialization takes
socket ownership only on success; its caller closes the socket on failure.
The poller is borrowed and must outlive the owner. Disconnect and destruction
remove the readable watch before closing the socket. On Linux this removes the
entire epoll registration and synchronizes with
concurrent epoll scans while the descriptor still owns a reference, so final
socket release does not depend on the waiting thread returning to userspace.
Destruction also releases the engine, including retained responses. Before
destruction, the scheduler must cancel application lifetimes and invalidate queued work.

A single serialized scheduler drives `step`, response submission, cancellation,
and readiness delivery. Each step performs at most one write (up to 16 KiB by
default) and one read (up to 16 KiB). No socket operation waits for readiness.
Successful I/O leaves the owner runnable; it must be queued again even when a
scheduling turn ends before EAGAIN. Otherwise edge-triggered epoll/kqueue could
leave unread input or pending output without a new event. Observers only queue
work for execution between engine calls.

A full socket send buffer enables writable readiness without disabling reads.
When output empties, writable interest is removed. HTTP/2 flow-control stalls
wait for incoming frames rather than polling writable sockets continuously.
A TCP read EOF preserves output that can still be serialized; after that output
is exhausted, the connection closes. Responses that need further peer credit
cannot finish after EOF. Socket/protocol errors terminate only that owner; the
scheduler removes it and releases its resources.

Each readiness token must be unique across connection reuse, including queued
stale events. `ready` ignores mismatched tokens and terminal owners. The production
worker also tracks request/effect lifetimes, as described below.

## Bounds and failures

The engine supports at most sixteen admitted streams, with a configurable lower
limit. Header accounting includes name/value bytes plus 32 bytes per field and
is cumulative across initial fields and request trailers. Exceeding this cap
resets the affected stream. The finite engine fixture also caps total body
bytes; production readers apply the whole-body or streamed-body limit.
The observer may have received a valid prefix before rejection and must discard
its queued request state on closure. nghttp2 handles protocol framing and HTTP/2
field validation; a fatal engine failure makes further driving operations fail.

The connection allocation domain counts nghttp2 session allocations, copied
response bodies, and their alignment prefixes against one byte limit. Reallocation
counts both old and replacement allocations during copying; a failed growth
preserves the old allocation. Session creation, input processing, response
submission, and output serialization propagate allocation errors. Partial
initialization and destruction release retained allocations exactly once.
The small engine object and temporary callback-registration object are outside
this limit; the engine's stream table has a fixed size. Observer/application
allocations are outside this domain and require separate bounded admission.

The finite `Engine.create` fixture uses automatic receive-window replenishment
and bounded finite request sizes. Production uses `Engine.createIncremental`:
consuming queued input returns credit explicitly, with connection and worker
budgets bounding retained input. `Handler.duplex` coordinates production input
and output independently; see [HTTP/2 streaming](http2-streaming.md). Finite response trailers and generic execution
deadlines are supported. Production scheduling, GOAWAY drain, and observability
are described below; streaming gates are tracked in the [gRPC plan](../plans/grpc.md).

## Request leases

The internal `requests.zig` registry separates protocol closure from execution
completion. It has sixteen fixed slots and is serialized by its connection owner;
it is not safe for independent worker threads to mutate directly. Tickets include
a unique connection token, a checked monotonic sequence, and a slot index. Initial
header completion records the monotonic timestamp once. A queued ticket can be
claimed once; duplicate, closed, and recycled tickets cannot start execution.

Protocol closure immediately releases unclaimed or finished slots. A claimed slot
remains reserved until execution calls `finish`, even after reset or disconnect.
The executor must cancel its effects and release request-owned resources before
finishing that lease. The registry owns no fibers, buffers, or Roc allocations.
Sequence exhaustion rejects new leases instead of wrapping. The owner must supply
a different connection token when replacing the registry.

The independent-client fixture uses these leases around its finite echo execution.
Lease bookkeeping alone does not cancel effects; the worker integration below
records parked fibers and wakes them after protocol closure.

## Request metadata mapping

`bridge.requestFromHttp2` accepts a complete, admitted initial field section after
engine validation. It must run outside engine callbacks, with copied input kept
alive until conversion returns; a rejected prefix or request trailers are not an
initial field section. The owner remains responsible for wire validation, header
and body limits, and stream admission. Both the fixture and production owner
use this adapter during request handoff.

The adapter recognizes the existing eight application methods and sets
`Http.Version.Http20`. It rejects missing, repeated, unknown, or out-of-order
pseudo-headers, unsupported methods (including CONNECT and TRACE), invalid schemes,
and targets outside origin-form or OPTIONS `*`. It reuses the HTTP/1 target syntax
and path policy without percent-decoding path or query bytes. The scheme is
validated but is not stored in the current Roc request representation.

A nonempty valid authority is required, using `:authority` or a single fallback
`host`. The adapter emits one `host` field so existing authority helpers work.
When both inputs exist they must match ignoring ASCII case; no default-port,
percent-escape, or IP spelling equivalence is inferred. This conservative policy
rejects ambiguous authority metadata. Pseudo-headers are removed from the ordinary
header list. Repeated ordinary fields retain their order, except Cookie fields,
which become one field at the first Cookie position joined with `; `, as required
by [RFC 9113 section 8.2.3](https://www.rfc-editor.org/rfc/rfc9113.html#section-8.2.3).

The caller supplies a budgeted scratch allocator for the normalized field array
and any joined Cookie bytes. Temporary storage is freed on success and failure;
the shared request builder copies the result into Roc ownership and rolls back
partial allocations. Only finite body bytes are supported here. This mapping
adds no listener negotiation, body reader, or application dispatch capability.

## Metadata handoff and finite body reads

`Owner.requestMetadataOwned` checks the lease and engine before and after copying
initial fields through `requestFromHttp2Metadata`. Unlike the finite handoff, this
leaves connection input owned by its registry on success or conversion failure.
The resulting request owns its metadata and carries a process-unique body token;
it contains no borrowed connection bytes or HTTP/2 identity.

The request fiber installs a body-reader callback in its own locals. A read checks
fresh expiry and engine admission under the connection lock, then either copies
owned body bytes or suspends without holding the lock. Ordinary handlers wait for complete input; streaming callbacks receive
chunks before EOF. A stricter route limit can fail a request before EOF. Input remains bounded by server and
connection limits until finish/reset/disconnect releases it. No borrowed view
survives suspension, and the callback follows the fiber across worker threads.
Completion clears the binding; abandonment releases the request heap and the
next fiber preparation clears all request-local capabilities.

## Finite stream registry

`http2.streams.Streams` combines bounded input and generation-checked request
leases in sixteen fixed slots. The connection owner serializes all operations
and keeps the table and its shared input budget at stable addresses. Only engine
callbacks from admitted, validated streams may supply fields and data.

Initial headers record the receipt timestamp once. `next` admits finite execution
only at body EOF; the internal `nextMetadata` entry can claim it immediately after
initial metadata completion. Both entries share the same one-shot claim, so body
EOF cannot dispatch a metadata-claimed request again. Between engine calls, either
entry emits one stream cancellation or one claimed execution containing its
ticket, timestamp, and borrowed input. Input limit/allocation failures release storage and queue one
cancellation without affecting peers. Invalid callback ordering is an error to
the owner. Capacity or sequence exhaustion is an admission error; no callback
resumes application code or enters the engine recursively.

The owner must consume the borrowed input synchronously, for example through
`requestFromHttp2Input`, before handing owned values to another thread. The table
and shared budget are not thread-safe. Closing a stream or disconnecting releases
input and invalidates unclaimed work; a claimed slot remains reserved until
request cleanup calls `finish`. Finishing releases any remaining input, rejects
stale or duplicate tickets, and cannot release a reused slot. Disconnect also
prevents further admission. If execution finishes before input EOF, subsequent
validated DATA and trailer callbacks are discarded without allocating. The engine
still enforces cumulative input limits, and the lease slot stays reserved until
protocol closure. The caller must enforce read/write deadlines while that stream
remains open. The registry does not itself cancel effects or retain Roc values,
and it must outlive all claimed executions.

The independent-client fixture checks both finite echo execution and metadata-only
replies followed by late body/trailer input. Production worker dispatch uses
`nextMetadata` under the connection lock and installs the request-scoped reader
described in [metadata handoff](#metadata-handoff-and-finite-body-reads). The independent echo fixture retains EOF-gated `next` by default.
Production reads return credit as described in the [engine input contract](http2-streaming.md#engine-input).

## Internal execution deadlines

Request leases can install a generic nanosecond duration from initial HEADERS
completion, clamped to a caller-supplied server maximum. `headersElapsed` reports
time since that same monotonic anchor. Body waits and execution queueing do not
restart it. Repeated installation can only tighten the deadline; zero expires
immediately, and addition saturates at the clock's maximum value.

The serialized owner checks expiry before and after Roc input conversion, and
before finite response submission. Scheduler ticks also expire body-waiting, queued and running leases.
Expiry invalidates dispatch and response admission immediately, releases retained
input, and queues one expiry completion (a registered response or stream reset). A running lease continues to pin its
slot until request cleanup finishes. The production scheduler uses the existing
cancellation path to wake suspended work and preserves a timeout outcome for an
admitted execution, even if late response conversion subsequently fails. This
does not preempt arbitrary Roc computation or promise real-time scheduling.

Successful finite response admission under the connection lock commits the
response outcome. Later execution expiry cannot replace it; response-write
limits continue to govern flow control and socket delivery, including trailers.
Expired or closed leases cannot be revived by installing another duration.

`Server.Limits.http2_execution` configures a listener-wide cap as
`Server.ExecutionLimit.Unlimited` (default) or `Milliseconds(duration)`. Finite
durations take 1 to 18,446,744,073,709 milliseconds; invalid values fail startup.
The bridge converts them to checked nanoseconds, and the connection installs the
cap when initial headers complete, before body EOF or execution admission.
Rejected header input already awaiting cancellation does not acquire a budget.
This setting applies only to HTTP/2 and does not change HTTP/1 timeouts.

`RequestExecution` lets Roc `BeforeBody` stages install tighter per-request
budgets before body waits. Integrations remain responsible for parsing protocol
metadata and selecting the duration.
The host does not interpret gRPC metadata or synthesize gRPC status fields.
The independent socket fixture installs a fixed generic budget at metadata
completion and verifies unfinished-body cancellation and unrelated-stream progress.

## Production HTTP/2 listeners

`Server.ListenOptions.protocol` selects `Http1` (the default) or explicit cleartext
prior-knowledge `Http2`, independently of TCP/Unix addressing. One initialized
model and the existing worker threads serve both protocols. The HTTP/2 path
executes routing and `BeforeBody` stages after initial headers. Ordinary handlers
wait for finite input EOF. It accepts finite responses with trailers and
[incremental callback responses](http2-streaming.md#production-callback-writer).
File streams and non-default writer modes reset their stream. `Handler.streaming`
receives bounded input chunks before EOF.

Each connection table slot optionally owns `http2/connection.zig`. Its connection
lock serializes every engine call, input conversion and response submission.
Callbacks only update copied input and closure state. The event loop queues a
connection generation plus a stream ticket; claiming the job is separate from
claiming the protocol lease. Closed queued/running leases pin the connection slot
until executor cleanup. Stale events and completions cannot address a reused slot.

Request fibers share the production wait registry and may resume on another Roc
thread. Parking records the fiber and wait serial under the connection lock;
closure signals that wait, including a wake before registry insertion. Body waits
also record their active read limit: queued bytes, EOF, rejection, or exceeding it wakes
the reader. Parking rechecks that condition under the same lock to avoid losing
completion between observing incomplete input and registering the wait. Other
hosted I/O waits are not woken merely because body input arrives. Resumption
removes the parked pointer before running Roc. Normal completion consumes Roc
values before heap release; cancellation/crash closes borrowed resources and
abandons the heap before finishing the lease. No connection lock is held while
application code executes or yields.

Transport turns perform at most four bounded owner steps. Readiness drives them;
the acceptor tick also advances runnable owners so edge-triggered input left after
a turn is not stranded. Pending frame bytes remain owned by nghttp2 until written.
The serialized owner protects response copying from concurrent peer reset.

Each connection supports 16 streams, 16 KiB field sections and input queues,
and finite responses up to 2 MiB. The pre-SETTINGS input flight and input-credit
rules are defined in the [streaming contract](http2-streaming.md#engine-input). Input/conversion storage and session/output
storage each have 16 MiB ceilings. A thread-safe 128 MiB worker budget bounds all
HTTP/2 connection, input and session allocations; this is separate from the Roc
request heap accounting. Admission limits and queue expiry apply to stream jobs.
Server input-limit failures reset streams; allocation/transport failure can close
the connection. A route's tighter `BodyLimit` produces `TooLarge` and the normal
413 reply, including before EOF. Route limits cannot increase the finite server
cap for whole reads. `Handler.streaming` uses the independent streamed-body
limit and consumes network input incrementally. Queued jobs still finish their
leases after a disconnect.

Initial/idle connection timeouts cover empty connections. Header/body deadlines
cover incomplete streams. Body and response-write deadlines are independent:
early finite replies retain the input deadline until EOF, and EOF does not clear a
pending response-write deadline. A streamed response that completes first resets
unfinished input with `NO_ERROR` after terminal consumption. That completion
releases its queue and ends the input deadline before the queued reset closes
the protocol stream. The write deadline ends when the transport
consumes the final response byte, including terminal HEADERS/CONTINUATION or
trailers; serialization alone does not complete a write. Submitted responses retain their write deadline
through flow-control or socket stalls. An unfinished header block closes the connection because decoding spans the
connection; body/write timeouts reset the stream. A blocked socket that cannot
deliver that reset closes. These are I/O deadlines, not generic
RPC execution deadlines. Request IDs retain the configured policy. Response access
entries are recorded after terminal frame bytes leave the owner buffer; disconnect
records pending entries as client-closed.

Drain sends GOAWAY with the engine's last processed stream ID. Existing admitted
streams may finish, including those still receiving a body. Once no stream or
execution remains and pending bytes are flushed, the connection closes. The
existing process drain deadline remains the final shutdown bound.

## Request execution controls

`RequestExecution.elapsed_nanoseconds!` and `limit_nanoseconds!` act on the current
HTTP/2 request fiber. The fiber holds a host-only callback to its generation-checked
stream lease; there is no application-visible transport handle or thread-local
request identity. The callback holds the connection lock, reads a fresh monotonic
clock, checks expiry, and optionally tightens the duration from initial header
completion. It cannot extend an existing server or application deadline.

If execution has closed or expired, the effect ends the fiber without returning
to Roc. The scheduler's existing abandonment path releases request allocations,
held permits and borrowed resources; expiry retains the timeout access outcome.
Otherwise the elapsed operation returns the nanoseconds since initial headers.
Outside an HTTP/2 request, these operations report `Unavailable`. The effect binding
lasts through the Roc invocation and follows fiber suspension/resumption.

`BeforeBody` stages can install a deadline before any body wait. A duration already
elapsed during queueing or another metadata effect stops execution before the next
Roc statement. Ordinary handlers still receive a complete body. Protocol timeout
parsing stays in Roc integrations; the host neither parses `grpc-timeout` nor creates
gRPC statuses.

`limit_with_response!` atomically tightens the same deadline and registers a finite
`Http.Response`. Under the connection lock, the host validates the response with
the ordinary HTTP/2 encoder rules and copies its body and fields into the bounded
connection allocator. It retains no Roc references. Invalid responses or failed
allocation return `InvalidResponse` without changing the previous registration or
deadline. A successful repeated call replaces the response but cannot extend the
existing deadline. HTTP/1 and initialization return `Unavailable`.

Expiry invalidates the execution lease and queues completion. Between engine
callbacks, the owner submits the copied response instead of a reset, then frees
the snapshot. Request cleanup may finish before this submission without freeing
the queued snapshot. Normal response commitment, protocol closure, and disconnect
also release it. The same connection lock serializes these paths. Client reset,
body/write timeout, and forced shutdown never select the expiry response by
themselves. If no response is registered when execution expires, reset remains
the fallback. Normal response-write and incomplete-input timeouts still apply;
registration does not guarantee delivery to a closed or stalled peer.

The integration selects gRPC status and metadata in Roc. Expiry bypasses router
response middleware and cannot call back into abandoned application code.

## Verification

| Layer | Evidence and boundary |
|---|---|
| Engine and owner | [Engine checks](../../tests/http2-engine/README.md): framing, partial writes, socket backpressure, allocation faults, stale leases, and synthetic Roc ownership handoffs. |
| Roc execution | [Roc fixture](../../tests/http2-roc/README.md): actual ABI and all backend/allocator combinations, detached heaps, suspended sleep/TCP reads, cancellation and resource recovery. Byte-driven and serialized; it does not establish cross-thread resumption or production scheduling. |
| Production listeners | [Listener checks](../../tests/http2-listener/README.md): real supervisor/workers, TCP/Unix, peer progress, limits, deadlines, observability and drain. |
| Finite acceptance | [Acceptance record](../plans/http2-finite-acceptance.md): combined evidence, baseline revisions and execution-target limitations. |
| Unary integration | [Unary checks](../../tests/grpc-unary/README.md): generated independent clients, metadata, status, deadlines and proxy interoperability. |

The isolated fixtures complement production tests; neither substitutes for the
other. Test READMEs describe reproduction commands and detailed case coverage.
