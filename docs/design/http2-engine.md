# Internal HTTP/2 engine

The host build includes the nghttp2 1.71.0 protocol library. The internal adapter
in `platform/host/http2/engine.zig` and the connection owner in
`platform/host/http2/owner.zig` are exercised by a separate socket fixture.
It is not yet connected to the production listener or Roc request scheduler;
applications still use HTTP/1. The [gRPC plan](../plans/grpc.md) records the remaining
milestone 1 work.

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

Keep nghttp2 for now. Reassess `http2.zig` when its protocol behavior, externally
woken streaming, maintenance, and supported compiler/targets meet roxum's needs;
a release label alone is not a migration criterion. Rust is not an adoption
candidate for this host. Monitor nghttp2 upstream security updates and review
version changes together with the source list, generated version header,
package hash, license, and independent-client checks.

## Serialized ownership and I/O

An `Engine` has a stable address until `destroy`. One owner calls its methods;
concurrent use is forbidden. A reentrant call from an observer is rejected.
Observers copy or queue borrowed headers/data and stream notifications; they
must not run application code, block, retain the borrowed slices, or destroy the
engine. A close notification invalidates the stream identity for that engine.
Destroying the engine releases all its resources without notifying observers;
the eventual connection owner must separately cancel its request lifetimes.

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
The poller is borrowed and must outlive the owner. Destruction closes the socket
and releases the engine, including retained responses. Before destruction, the
scheduler must cancel application lifetimes and invalidate queued work.

A single serialized scheduler drives `step`, response submission, cancellation,
and readiness delivery. Each step performs at most one write (up to 16 KiB by
default) and one read (up to 16 KiB). No socket operation waits for readiness.
Successful I/O leaves the owner runnable; it must be queued again even when a
scheduling turn ends before EAGAIN. Otherwise edge-triggered epoll/kqueue could
leave unread input or pending output without a new event. The fixture grants
32 steps per connection per turn, and polls without waiting while work remains.
Observers only queue work, which the fixture executes between engine calls.

A full socket send buffer enables writable readiness without disabling reads.
When output empties, writable interest is removed. HTTP/2 flow-control stalls
wait for incoming frames rather than polling writable sockets continuously.
A TCP read EOF preserves output that can still be serialized; after that output
is exhausted, the connection closes. Responses that need further peer credit
cannot finish after EOF. Socket/protocol errors terminate only that owner; the
scheduler removes it and releases its resources.

Each readiness token must be unique across connection reuse, including queued
stale events. `ready` ignores mismatched tokens and terminal owners. The fixture
assigns monotonically increasing tokens and checks connection-slot reuse. This
is a transport contract, not yet generation-safe Roc request/effect scheduling.

The fixture uses the same kqueue/epoll backend as the production host and admits
two connections for independent-client tests. It checks real socket backpressure,
writable resumption, aborted writes, invalid-preface isolation, and TCP half-close.
The production worker connection table, request scheduler, drain coordination,
listener protocol selection, and public Roc APIs are still separate integration
work. Fixture timeouts are test bounds, not production deadline support.

## Bounds and failures

The engine supports at most sixteen admitted streams, with a configurable lower
limit. Header accounting includes name/value bytes plus 32 bytes per field and
is cumulative across initial fields and request trailers. Request body bytes
have a separate cumulative cap. Exceeding either cap resets only that stream.
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

Request input currently uses automatic receive-window replenishment with bounded
finite request sizes. A streaming request reader must replace that with explicit
consumption accounting and aggregate backpressure before this adapter can serve
unbounded or full-duplex requests. Trailers, request deadlines, GOAWAY drain,
production scheduler integration, and corresponding observability are not yet
implemented here. The [transport design](../plans/http2-transport.md) describes
those proposed contracts, not capabilities of this adapter.

## Verification

[Engine checks](../../tests/http2-engine/README.md) combine fault-injected allocator
unit tests with an independent client. They do not substitute for the later Roc
backend/allocator, scheduler-cancellation, malformed-frame fuzzing, Unix listener,
or production shutdown acceptance gates.

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
Production worker dispatch, cross-thread completion messages, and cancellation of
Roc effects are still pending; lease bookkeeping alone does not implement them.

## Request metadata mapping

`bridge.requestFromHttp2` accepts a complete, admitted initial field section after
engine validation. It must run outside engine callbacks, with copied input kept
alive until conversion returns; a rejected prefix or request trailers are not an
initial field section. The owner remains responsible for wire validation, header
and body limits, and stream admission. This adapter is not yet wired into the
production owner or Roc scheduler.

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

## Finite request input

`http2.input.Input` copies borrowed initial headers and DATA callback bytes into
connection-owned storage. `headersComplete` freezes the initial field array and
makes its view available before body EOF. Later header callbacks are trailers and
are omitted; the engine still validates and accounts for them. `end` exposes the
finite body. This collector neither validates HTTP fields nor implements streaming
receive credit, and only accepts callbacks from a validated, admitted stream.

Each input enforces cumulative initial-header accounting (name/value bytes plus
32 bytes per field) and a body-byte limit. Inputs share a stable `Budget` owned by
the serialized connection owner. That aggregate allocation ceiling includes field
arrays, byte-buffer capacities, 16-byte allocation prefixes, and old plus new
allocations during growth. Its Zig allocator supports alignments up to 16 bytes.
The fixture normally uses a separate 128 KiB input budget per connection, in addition to
the engine's session budget; neither budget draws from a Roc request arena.

A limit or allocation failure rejects the input and releases its retained storage.
The owner queues a stream cancellation outside the callback batch. Invalid call
ordering returns `InvalidState`; rejected input cannot become ready again.
Protocol closure or disconnect releases buffered input. Borrowed views must be
copied into Roc ownership before input release or dispatch to another thread;
these views do not pin the input across protocol closure. `deinit` also releases
partially collected input and is safe after rejection.

The independent-client fixture uses this collector for finite echo requests and
checks copied metadata, fragmented body input, trailer exclusion, stream resets,
and disconnect cleanup. A smaller fixture budget exercises input rejection,
unrelated-stream progress, and capacity reuse after repeated cancellations. Production worker integration and application effect
cancellation remain pending.

## Input handoff to Roc ownership

`bridge.requestFromHttp2Input` consumes a completed finite `Input`. It must run
outside engine callbacks, with the caller's request allocation domain active.
Conversion uses the connection input budget for normalized fields and joined
Cookie scratch, while the resulting request uses the supplied Roc allocator.
Engine input and bridge metadata share the same borrowed field representation;
no intermediate field-array copy or C engine types are needed at this boundary.

Before EOF, or after rejection/release, handoff returns `InvalidState` without
changing input or allocating Roc values. Once EOF is present, the attempt consumes
input on success or failure. It releases temporary scratch and buffered input,
including on invalid metadata or allocation failure. A second handoff therefore
fails. Other inputs sharing the budget remain owned by their respective streams.

A successful result has no borrowed references to the connection input or request
ID. The caller retains it until the consuming Roc invocation, or releases it with
generated cleanup if dispatch is cancelled. Releasing connection input does not
finish a request lease or cancel pending execution. Production queue integration,
live Roc invocation, and streaming body handoff remain separate work.
