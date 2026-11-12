# Internal HTTP/2 engine

The host build includes the nghttp2 1.71.0 protocol library. The internal adapter
in `platform/host/http2/engine.zig` and the connection owner in
`platform/host/http2/owner.zig` are exercised by a separate socket fixture.
Opt-in TCP/Unix listeners now use the production worker scheduler for finite
HTTP/2 exchanges; HTTP/1 remains the default. The [gRPC plan](../plans/grpc.md) records the remaining
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

## Explicit finite response completion

The internal engine also provides `beginResponse` and `finishResponse`. The first
copies a finite body and leaves the stream open; the second copies final fields
and submits terminal HEADERS exactly once. For a nonempty body, completion is
allowed only after the DATA provider has reached EOF. Until then it returns
`InvalidState`, including when the peer withholds stream credit. EOF uses
NO_END_STREAM on the last nonempty read, so no extra DATA credit is required.
Empty bodies use initial HEADERS without END_STREAM and can complete even with
zero stream credit. Output ordering is retained when earlier bytes are only
partially written. This is not an incremental response writer.

Final fields have independent `header_bytes` and 64-field bounds. Pseudo-fields,
connection-specific fields, content length, host, trailer declarations, content
type/encoding/range, and authentication fields are rejected. Metadata names such
as `grpc-status` have no special host interpretation. Invalid fields or allocation
failure leave completion retryable; cancellation and closure make it unavailable.
HEAD and status 204/205/304 cannot start this completion mode. Ordinary `respond`
retains its existing one-call finite response behavior.

`respondWithTrailers` connects finite Roc responses to this completion mode. It
validates final fields and copies their names and values into session-budgeted
storage before committing initial HEADERS. `output` submits terminal HEADERS
after DATA EOF, respecting pending partial writes. Reset, destruction, and
successful submission release the retained copy; a submission allocation failure
terminates the connection. No request-owned reference survives response cleanup.
The existing response-write deadline remains active through terminal output.
Public `Reply.with_trailers` / `Response.trailers` support finite replies only;
streaming completion remains separate work. Metadata stages can install generic
request deadlines before body reads.

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
is a transport contract; the worker integration below also tracks request/effect lifetimes.

The fixture uses the same kqueue/epoll backend as the production host and admits
two connections for independent-client tests. It checks real socket backpressure,
writable resumption, aborted writes, invalid-preface isolation, and TCP half-close.
The fixture is separate from the production worker integration described below.
Its timeouts are test bounds, not RPC execution deadlines.

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
unbounded or full-duplex requests. Finite response trailers and generic execution
deadlines are supported. Finite worker scheduling, GOAWAY drain and observability are
described below. The [transport design](../plans/http2-transport.md) describes
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
unrelated-stream progress, and capacity reuse after repeated cancellations. The
production connection uses the same collector under its worker lock.

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
finish a request lease or cancel pending execution. Production queue integration preserves that contract; incremental streaming body
handoff remains separate work.

## Metadata handoff and finite body reads

`Owner.requestMetadataOwned` checks the lease and engine before and after copying
initial fields through `requestFromHttp2Metadata`. Unlike the finite handoff, this
leaves connection input owned by its registry on success or conversion failure.
The resulting request owns its metadata and carries a process-unique body token;
it contains no borrowed connection bytes or HTTP/2 identity.

The request fiber installs a body-reader callback in its own locals. A read checks
fresh expiry and engine admission under the connection lock, then either copies
owned body bytes or suspends without holding the lock. Reads wait for finite EOF;
a stricter route limit can fail earlier. Input remains bounded by server and
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
`nextMetadata` under the connection lock and installs the finite body reader
described below. The independent echo fixture retains EOF-gated `next` by default.
Streaming receive credit remains separate work.

## Internal execution deadlines

Request leases can install a generic nanosecond duration from initial HEADERS
completion, clamped to a caller-supplied server maximum. `headersElapsed` reports
time since that same monotonic anchor. Body waits and execution queueing do not
restart it. Repeated installation can only tighten the deadline; zero expires
immediately, and addition saturates at the clock's maximum value.

The serialized owner checks expiry before and after Roc input conversion, and
before finite response submission. Scheduler ticks also expire body-waiting, queued and running leases.
Expiry invalidates dispatch and response admission immediately, releases retained
input, and queues one stream cancellation. A running lease continues to pin its
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

## Finite Roc response mapping

`bridge.OwnedHttp2Response` consumes one Roc response reference and prepares the
finite engine's field/body views. It normalizes field names to lowercase while
preserving field order, duplicate fields, and values. Scratch storage uses a
caller-supplied bounded allocator; values and body remain in Roc ownership until
`deinit`. Views survive moving the adapter value, but not its destruction. The
caller must submit them synchronously to the copying engine outside callbacks,
and call `deinit` exactly once after either submission success or failure.

The adapter accepts final statuses 200 through 599. It shares the existing HTTP/1
policy that application Content-Length, Transfer-Encoding, and Connection fields
are errors, and also rejects HTTP/2 connection-specific fields, pseudo-fields,
invalid syntax, and values with leading or trailing whitespace. The host adds
Content-Length except on 204 and 304. HEAD retains the representation length with
an empty transmitted body. Nonempty bodies on 204, 205, and 304 are rejected,
including for HEAD, consistently with the existing finite response contract.

Field limits include synthetic Content-Length and the :status accounting. At
most 64 ordinary fields reach the engine. The caller supplies header and body
limits matching the connection; the body bound also applies to a HEAD response's
retained representation. Allocation and validation failures consume the response
and release partial scratch. Engine submission still performs its own validation
and copies output before Roc cleanup; an error there remains the caller's
responsibility. Trailers have separate normalized views and field/byte limits;
the engine validates their semantics before committing the response. The adapter
does not provide a streaming writer.

## Owned response submission

`Owner.respondOwned` connects the finite Roc response adapter to the copying
engine. It consumes a response on success and on every failure. The serialized
owner supplies its stream registry and an execution ticket; the registry's
connection token must match the owner, and the ticket must identify a claimed,
still-open execution. Queued, finished, closed, stale, and foreign tickets cannot
submit output. The engine also checks protocol state, including resets whose
close notification has not yet arrived and duplicate response submission.

Conversion scratch shares the registry's connection input budget, using the
engine's configured header and response-byte limits. Scratch and the consumed
Roc response are released before the method returns, while successfully copied
output remains owned by the engine through partial writes and flow-control waits.
The caller must keep the Roc host and request allocation domain alive through
this synchronous operation outside callbacks, with the corresponding allocator
context active. Submission does not finish the
execution lease: the executor must clean up remaining request resources before
calling `finish`, including after submission failure.

The independent-client fixture uses synthetic Roc response values through this
path and checks that every response has released all Roc allocations before the
next transport step. Its test allocator poisons freed bytes. Focused integration
tests also cover stale execution, reset/disconnect, conversion failure, scratch
exhaustion, engine allocation failure, and output serialization after Roc cleanup.
These tests invoke generated ABI value helpers, not a Roc application. The real
Roc fixture and production listener checks cover invocation separately.

## Checked request dispatch handoff

`Owner.requestOwned` transfers finite input for a claimed execution into the
active Roc request allocation domain. The owner and registry connection tokens
must agree, and the ticket must still identify an open, running lease. The
engine also rejects a queued reset before its close callback arrives, a failed
session, reentrant calls, and streams with a response already submitted. These
checks allocate nothing and leave input unchanged.

After these checks, the input bridge consumes completed input on success or
conversion failure. Repeating the handoff returns `InvalidState`. The returned
request owns its metadata and body independently of connection input; reset or
disconnect cannot free those Roc values. The caller must consume the request in
Roc or release it with generated cleanup, then finish the execution lease. A
conversion failure also leaves that lease claimed until caller cleanup. No
engine call may interleave with this synchronous handoff.

The independent-client fixture now echoes bytes from the owned request and passes
its synthetic response through `respondOwned`. It releases both Roc values before
advancing transport output. Diagnostic header counts describe normalized ordinary
fields, including the synthesized Host field, rather than HTTP/2 pseudo-fields.
Unsupported methods and invalid application paths reset only their stream. This
exercises both ownership boundaries together. The real Roc fixture below also
checks invocation; production invocation is covered separately below.

## Real Roc execution fixture

`zig build test-http2-roc` links the current platform sources and generated ABI to
an actual Roc application. It runs all three compiler backends with the arena and
tracking allocators. The fixture host uses the same runtime/hosted exports as the
production entry point, and keeps its copied platform and target archives in a
per-run temporary directory.

A pinned independent HTTP/2 client supplies length-delimited batches of wire bytes
and decodes the output. The serialized fixture claims finite executions, activates
the request allocation context, hands off input, retains the initialized model for
`roc_handle`, and submits the returned response. It releases route metadata and
response ownership before resetting the request generation and finishing the lease.
Output serialization runs after the submitting request has released its values;
other request fibers may still be suspended. Arena
live bytes are checked before reset; tracking mode additionally checks zero request
allocations, the persistent baseline, canaries, and valid frees. The scalar-only fixture
model also permits a zero-persistent-allocation assertion after releasing its root.

Cases cover repeated model use beyond stream-slot capacity, fragmented input with
an independently progressing peer, reset before execution, HEAD, application errors,
routing misses, request conversion rejection, and invalid application responses.
Each invocation runs on a request fiber with fiber-local allocation context. The
first hosted sleep detaches its live request heap and advances the shared request
generation; later waits reuse the detached heap. A peer can complete while that
invocation waits, and the original request metadata/body remain valid on resume.
Reset and disconnect invalidate submission and retain the running lease until
cleanup. Between callback batches, the fixture wakes closed invocations with a
client-gone stop. The real sleep effect stops before returning to application code;
cleanup releases held resources, abandons the detached heap, clears fiber-local
allocation context, and finishes the lease before destroying the fiber. Normal
completion still releases Roc values before checking and releasing the heap.

Tests cover two short sleeps with normal completion, plus reset and disconnect
during long sleeps that must not complete. A concurrency permit remains occupied
while its handler waits and is available to a peer after reset cleanup. Cancelled
requests deliberately use bulk reclamation rather than normal decref checks;
aggregate live request bytes must return to zero after all invocations finish.

These are byte-driven integration checks, not a production listener or scheduler.
Suspensions register with the production `scheduler.Waits` only after heap
detachment. A real kqueue/epoll backend collects socket readiness, wakes, and expired
timers, removing wait registrations before resumption or destruction. Cancellation
uses the installed `fiber_wait` registry rather than its unregistered-wait fallback. Checks count
registrations, collections, and wake events, and require no jobs or waits at exit.
Ordinary batch boundaries poll without blocking; empty records drain outstanding
waits using the production blocking-wait deadline calculation. An immediate peer
in the same batch still precedes the delayed response, but later batches need not
precede a timer that has expired.

A separate interactive client exercises real outbound TCP reads through the
production socket-wait hook. Its loopback upstream sends a byte only after the read
wait is registered, proving readiness-driven resumption and peer progress without timed
server delays. Reset and disconnect interrupt unanswered reads before the hosted
effect returns to Roc. Cleanup closes the borrowed connection (observed as upstream
EOF), releases a held permit, and reclaims the detached heap. A successful read
after reset also exercises reused request/wait slots. Normal completion explicitly
discards its upstream connection; registration and collection counts must balance.

No cross-thread resumption, TCP write/TLS cancellation, file-operation cancellation,
or crash isolation is exercised. The socket fixture continues to cover nonblocking
transport and backpressure independently. The production listener checks below
exercise the worker integration.


## Production finite HTTP/2 listeners

`Server.ListenOptions.protocol` selects `Http1` (the default) or explicit cleartext
prior-knowledge `Http2`, independently of TCP/Unix addressing. One initialized
model and the existing worker threads serve both protocols. The HTTP/2 path
executes routing and `BeforeBody` stages after initial headers. Ordinary handlers
wait for finite input EOF. It accepts finite responses and response trailers;
attempted response writers/file streams reset their stream instead of silently
returning an empty successful body. Incremental network body delivery remains
unsupported.

Each connection table slot optionally owns `http2/connection.zig`. Its connection
lock serializes every engine call, input conversion and response submission.
Callbacks only update copied input and closure state. The event loop queues a
connection generation plus a stream ticket; claiming the job is separate from
claiming the protocol lease. Closed queued/running leases pin the connection slot
until executor cleanup. Stale events and completions cannot address a reused slot.

Request fibers share the production wait registry and may resume on another Roc
thread. Parking records the fiber and wait serial under the connection lock;
closure signals that wait, including a wake before registry insertion. Body waits
also record their active read limit: EOF, rejection, or exceeding that limit wakes
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

Each connection supports 16 streams, 16 KiB field sections, the configured finite
body limit, and responses up to 2 MiB. Input/conversion storage and session/output
storage each have 16 MiB ceilings. A thread-safe 128 MiB worker budget bounds all
HTTP/2 connection, input and session allocations; this is separate from the Roc
request heap accounting. Admission limits and queue expiry apply to stream jobs.
Server input-limit failures reset streams; allocation/transport failure can close
the connection. A route's tighter `BodyLimit` produces `TooLarge` and the normal
413 reply, including before EOF. Route limits cannot increase the finite server
cap. `Handler.streaming` consumes the collected body in bounded parts, not as
network input arrives. Queued jobs still finish their leases after a disconnect.

Initial/idle connection timeouts cover empty connections. Header/body deadlines
cover incomplete streams. Body and response-write deadlines are independent:
early replies retain the input deadline until EOF, and EOF does not clear a
pending response-write deadline. Submitted responses retain their write deadline
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

`zig build test-http2-listener` invokes the standard verification runner for all
three Roc backends and both allocators. It uses the production host and supervisor,
two worker threads, and independent clients on TCP and Unix listeners. Checks cover
fragmented input, slot reuse, HEAD, application/adapter errors, effect suspension,
TCP cancellation and permit recovery, body-limit boundaries, incomplete-body
timeouts, request IDs/access records and GOAWAY. The internal fixture continues to
provide more controlled allocator and wait-registration checks. These checks cover finite core transport capabilities; they do not claim generated
gRPC services or streaming RPC support.

## Fixed-byte gRPC client probe

The [production listener probe](../../tests/grpc-probe/README.md) uses a pinned
native gRPC client to verify exact finite message bytes, empty messages, final
status and error metadata on TCP and Unix sockets. Missing status and truncated
message envelopes are negative controls. The Roc fixture supplies fixed bytes
and generic HTTP trailers; the host has no gRPC-specific parsing or status policy.
This verifies finite transport interoperability, not generated services or RPC
deadline handling. Protocol-specific timeout parsing belongs to the planned gRPC integration.

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
Outside an HTTP/2 request, both operations report `Unavailable`. The effect binding
lasts through the Roc invocation and follows fiber suspension/resumption.

`BeforeBody` stages can install a deadline before any body wait. A duration already
elapsed during queueing or another metadata effect stops execution before the next
Roc statement. Ordinary handlers still receive a complete body. Protocol timeout
parsing stays in Roc integrations; the host neither parses `grpc-timeout` nor creates
gRPC statuses.
