# Finite HTTP/2 input and response adapters

The [HTTP/2 engine](http2-engine.md) shares metadata and response conversion
between production code and its wire fixtures. The finite input collector is
used by fixtures. Production retains the metadata snapshot and consumes DATA
from the incremental engine queue.

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
callback writers complete with `ResponseWriter.finish!`. Metadata stages can install generic
request deadlines before body reads.

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
production connection uses the same metadata snapshot under its worker lock,
with `observeData` counting cumulative payload bytes instead of copying them.
Its engine owns the incremental queue.

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
finish a request lease or cancel pending execution. For production incremental reads, see the [streaming contract](http2-streaming.md#production-request-reads).

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
Content-Length except on 204, 304, and responses with trailers. HTTP/2 frames
delimit those bodies; omitting the length also prevents intermediaries from
ending an empty response before forwarding its trailers. HEAD retains the representation length with
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
