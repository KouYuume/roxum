# HTTP/2 streaming contract

Status: production `Reply.stream` output, explicit terminal metadata and execution
expiry trailers, production incremental input and streamed-response half-close
cleanup and request-scoped duplex coordination are implemented. Generated client-streaming uses the incremental input path.
The gRPC integration also supports manual duplex routes. Generated bidirectional bindings remain a target for [0.3](../plans/grpc-streaming-0.3.md).

## Production callback writer

On HTTP/2, `Reply.stream` and `ResponseWriter.write!` send incremental DATA.
The writer splits large caller buffers into bounded engine chunks. Those caller
buffers remain request-owned across suspension; each admitted chunk is copied.
The last admitted chunk may still be pending when write returns. A successful
write is not a peer-delivery acknowledgement.

Initial metadata is normalized and validated before commit. The connection lock
covers state inspection, engine operations and bounded nonblocking transport turns.
Admitting output drives transport immediately; a blocked write or completion parks
its request fiber without holding the lock. Parking and transport progress
check the same readiness predicate, with the connection generation, stream lease
and wait serial protecting against stale wakes and slot reuse. Socket readiness
and WINDOW_UPDATE can resume output independently of incoming request EOF.

Successful callback return (`Ok({})`) implicitly completes with empty trailers
unless the writer already finished explicitly. Implicit and explicit completion
drain accepted DATA and wait until the terminal HEADERS have been consumed by
socket writes. Returning `Err(StreamClosed)` aborts unfinished output without a
successful terminal section. Protocol closure alone is not
completion: nghttp2 may close a stream before those bytes leave the output cursor.
The event loop retains its terminal-output deadline and access-log consumption
tracking. Route metadata is recorded before starting output. `maximum_streams`
counts active callback writers; excess writers receive 503. HEAD and bodyless statuses send only headers
and do not enter the callback. Normal cleanup and abandoned fibers release the
writer's quota once.

This callback API currently supports default writer options and uncompressed
output only. Keep-alive payloads, `ends_on_drain`, known-length file writes and
trailers attached with `Reply.with_trailers` remain unsupported for callback
writers. Use `ResponseWriter.finish!` for streamed trailers; unsupported writer
options reset the attempted stream. Request reads use bounded incremental input;
`Handler.duplex` continues reading after streaming headers, until completion is selected.

`ResponseWriter.finish!(writer, trailers)` validates and copies bounded fields,
selects normal completion once, and waits for socket consumption. Invalid fields
leave the writer open for retry; a second finish or writes after finish fail.
HTTP/1 returns `Unavailable`. Header names are normalized to lowercase and the
finite-trailer field/count/byte rules also apply here. Field storage is allocated
only for registered or selected terminals and charged to the connection/worker
budgets; idle connections do not reserve a full field table per stream.

`RequestExecution.limit_with_trailers!(duration, trailers)` atomically registers
expiry fields and tightens the metadata-anchored deadline before initial output.
It replaces any finite expiry snapshot; a later finite registration replaces it.
Invalid fields or allocation failure do not alter the previous registration.
On expiry after headers, Roc work is abandoned while the serialized owner drains
accepted DATA and submits the copied terminal fields. Before headers, or without
registered expiry trailers, expiry resets the stream. A finite expiry response
cannot replace committed streaming headers.

The first accepted finish or expiry selects the terminal. Normal selection stops
execution expiry, not the response-write timeout. Reset, transport failure and
forced shutdown prevent further delivery. A callback crash resets its stream.
Graceful drain permits completion until the process deadline; forced drain exits
with status 1 and releases process resources without running application cleanup.
No protocol-specific status is manufactured by the host.

Successful `finish!` permits immediate result handling after terminal consumption,
but does not establish a new execution lifetime. Further waits can be cancelled
by normal stream closure; complete required application I/O before calling finish.
`AfterHandler` middleware still runs before initial output, not at completion.
Held native permits and writer quota are released once during request cleanup;
normal callbacks remain alive through terminal consumption, whereas cancellation
abandons them. Access logging retains the selected timeout/failure outcome.

When streamed output completes before request EOF, the engine queues
`RST_STREAM(NO_ERROR)` only after the transport consumes the full terminal field
section. This applies to explicit finish, callback return and selected expiry
trailers, including empty responses. It releases unread input and returns
connection credit without reopening the stream window. The input deadline ends
at terminal consumption, so it cannot overwrite completion while the reset awaits
serialization. Input EOF arriving first
needs no reset and does not stop response writes. This follows
[RFC 9113 section 8.1](https://www.rfc-editor.org/rfc/rfc9113.html#section-8.1).
The protocol lease remains reserved until closure, and request resources remain
pinned until callback cleanup. A normal completion remains `handled` in access
logs; an expiry completion remains `timeout`. A subsequent callback wait is
cancelled after closure, just as when request EOF precedes completion.

## Engine output

The serialized owner calls these internal Zig methods:

```zig
beginStreamingResponse(id: StreamId, status: u16, headers: []const Header) Error!void
writeStreamingResponse(id: StreamId, bytes: []const u8) Error!bool
finishResponse(id: StreamId, trailers: []const Header) Error!void
```

Begin copies initial fields and commits the response choice. It rejects
Content-Length, HEAD and bodyless statuses. Write copies at most one chunk;
`true` means the caller can release its bytes, not that the peer received them.
`false` retains nothing and requires driving output before retrying. Empty writes
never end output. Oversized writes fail even while another write is pending.

| Output state | Operation | Result |
|---|---|---|
| Uncommitted | Begin | Initial HEADERS queued; response open |
| Open, previous chunk consumed | Write | One owned chunk queued |
| Initial HEADERS still queued, chunk pending, or serialized output pending | Write | Backpressure; retry without retaining bytes |
| Initial HEADERS, chunk or serialized output pending | Finish | InvalidState; drive output and retry |
| Open, no chunk or serialized output pending | Finish | Final HEADERS queued exactly once |
| Finishing | Write / finish | InvalidState |
| Reset / closed | Write / finish | Closed |

[nghttp2 permits one active DATA provider per stream](https://nghttp2.org/documentation/nghttp2_submit_data2.html). Each chunk ends its provider
without END_STREAM. Once copied into nghttp2's serialized output, the owned
chunk is freed. The output cursor retains the unsent suffix across partial socket
writes; callers must not mutate or retain that view. While any serialized output
is pending, admission is conservatively blocked for all streaming writers.
The owner must consume that suffix and retry writers fairly. This is socket
backpressure, not a requirement for credit on an unrelated stream.

After the last chunk, terminal HEADERS need no DATA credit, including an empty
response or a last chunk consuming the exact remaining window. Completion is
observed through `response_sent` only after the transport consumes END_STREAM.
Validation/allocation failure leaves an uncommitted operation retryable; reset,
disconnect and engine destruction release queued storage. No completion callback
or application code executes inside a provider.

The internal `stream_chunk_bytes` limit defaults to 16 KiB per stream. It is
separate from the finite `response_bytes` cap. Chunk copies and serialized
output share the existing session allocation budget. There is no accumulated
response-body buffer and no public configuration change in this slice.

## Engine input

`Engine.createIncremental` selects bounded receive queues with manual flow control.
The production owner uses this mode for all requests. `Engine.create` remains
available to finite engine fixtures. Incremental mode does not use `body_bytes`
as a cumulative cap: production readers enforce whole/streamed body limits,
and integrations remain responsible for message, total-work and duration limits.

`readRequest(id, destination)` copies into caller-owned storage and returns
`data(count)`, `pending`, or `end`. The destination must be nonempty. Reads drain
queued bytes before returning repeatable EOF; request EOF does not finish output.
Calls are serialized and forbidden inside observer callbacks. `data` notifications
report arrivals only; incremental consumers read the owned queue instead of
collecting another body from those borrowed callback bytes. Reset/rejection makes
reads fail with `Closed`; session failure also prevents further reads.

The separate, borrowed input budget must outlive the engine and share its owner.
Use the connection input/conversion budget backed by the worker allocator. Queue
capacity and allocation overhead are charged there; protocol allocations remain
in the session budget. Queue storage is allocated on first DATA and released when
empty, rejected, cancelled, closed or destroyed. A partial read frees logical
capacity but retains the bounded allocation until the queue empties.

`input_queue_bytes` defaults to 16 KiB (internal range 1–65,535). The engine
advertises it through SETTINGS. Before the peer acknowledges that setting, the
protocol permits the initial 65,535-byte window: queues admit that bounded flight
under the same aggregate budgets. Such an allocation can remain until drained;
a SETTINGS acknowledgment never discards already accepted input. Once acknowledged,
new input is limited by the smaller stream window. One stalled stream does not
pause connection parsing or other streams; enough stalled streams can still
exhaust the shared connection window.

Copying into a queue returns no credit. Reading returns connection and stream
credit once through nghttp2's consumption API, which batches WINDOW_UPDATE frames.
Cancellation, reset and rejected allocations discard unread payload and restore
only connection credit. The nghttp2 parser itself consumes padding and DATA it
ignores before invoking the payload callback; the adapter does not credit those
bytes again. Queue allocation failure resets that stream. Failure while recording
credit terminates the session, because a partial window update cannot be retried
safely. Destroying a disconnected engine releases queues without issuing credit.

## Production request reads

The existing internal `Http.RequestStream` capability feeds `Handler.streaming`
as bytes arrive. `Pipeline` still collects the whole body before ordinary handlers
run. No public token or new hosted ABI is needed. Metadata snapshots retain fields
and a cumulative byte count; payload lives only in the engine queue and the
current Roc-owned chunk (at most 16 KiB). The request heap accounts for Roc values.

Readers validate the connection's stream lease under its lock, copy a chunk into
request-owned memory, and drive a bounded transport turn to send receive credit.
When no bytes are ready they park the actual request fiber. Both parking and input
progress check the same level-triggered predicate, including queued bytes, EOF,
rejection and the current cumulative limit. Generation, lease and wait serial
checks prevent stale wakes; input never wakes a fiber waiting on unrelated I/O.
No connection lock or borrowed queue view survives a yield.

Whole reads retain the server's finite `maximum_body_bytes` cap; a tighter route
limit returns `TooLarge`. Streamed reads use `maximum_streamed_body_bytes`,
replaceable by `BodyLimit.streamed`, independently of the finite cap. Route limits
count received payload across chunks rather than each queue's size. Transport
failures, reset and body/execution timeout abandon the request using existing
cleanup; they do not resume Roc's abort callback. The HTTP/2 body timeout remains
an absolute deadline from metadata completion, including time spent in callbacks.

After an early finite response, finishing execution releases queued input and switches
the open request side to discard mode with credit recovery. Whole/unread requests
retain the finite server cap; streamed requests discard without accumulating more
payload. The input deadline and protocol lease remain until EOF or reset. This
preserves finite early response delivery. Streamed responses use the completion
reset described above. Duplex waits observe input and output independently.

## Request-scoped duplex coordination

`Handler.duplex({ begin!, ready! })` keeps application state in Roc and runs
`ready!` when any selected direction can progress. `begin!` receives the model
and request head before output; it returns initial state, status, headers and
`Handler.Interest.Read`, `Write` or `Both`, or rejects with an ordinary reply.
HTTP/1 returns 501 without invoking the callbacks.

The pipeline owns the input capability and evolving `OnChunk` checks.
`ready!` receives `Handler.DuplexEvent.{ input, writable }` and the scoped
`ResponseWriter`. Input is `Idle`, `Chunk(bytes)`, `End` or
`Failed(Handler.StreamEnd)`. Each chunk passes the middleware checks in order;
EOF runs their finish checks once. A check rejecting after headers aborts output,
since its replacement reply can no longer be sent. A body limit or recoverable
read failure reaches `Failed` so the integration can select terminal metadata.
Transport cancellation abandons the request instead of invoking another callback.
`AfterBody` does not run; `AfterHandler` runs before initial output.

The callback returns `Handler.DuplexNext.Await({ state, interest })` or
`Finish(trailers)`. Finish drains accepted DATA and waits for terminal socket
consumption. Returning `Err(StreamClosed)` aborts output. After `End` or
`Failed`, only write interest is valid; waiting on completed input aborts.
Invalid terminal fields abort output. Return `Finish` to complete a duplex handler rather than finishing the writer
inside `ready!`. Bodyless responses and exhausted writer quota skip `ready!`,
just as for `Reply.stream`.

`ResponseWriter.try_write!(writer, bytes)` accepts at most 16 KiB, returning
`Accepted` or `Pending`. Pending retains no bytes. Oversized writes return
`TooLarge` even under backpressure; other errors are `Unavailable`,
`InvalidState` and `StreamClosed`. HTTP/1 is unavailable. Accepted means
bounded ownership transfer, not peer delivery. The blocking `write!` remains
available, but using it in a duplex callback can deliberately stall input.

Read and write readiness are independent and level-triggered. Writable readiness
is a hint: other stream progress can make a subsequent try-write pending again. Select only the
directions the application can use: continually requesting write readiness
without producing output can spin. Both the parking path and transport progress
use the same combined predicate under the connection lock. Generation, stream
lease and wait serial validation prevent stale wakes; no lock or borrowed input
view survives suspension. EOF is reported once by the pipeline and does not
complete output. Request handles cannot extend the callback/request lifetime.
No general task spawning or mandatory read/write alternation is introduced.

## Target input and limits

The host delivers owned byte chunks, not gRPC messages. Copying into the receive
queue does not return receive credit. Taking a chunk releases queue storage and
returns its connection and stream credit once. Discarded bytes return connection
credit; stream credit is restored only while that stream remains open. Padding
must also be accounted for. Reset must not starve another stream's connection
window. No borrowed callback buffer survives a callback or yield.

| Input state | Event | Result |
|---|---|---|
| Open | DATA | Queue within byte budgets, signal readable |
| Open | END_STREAM | Drain queued bytes, then End |
| End | Read | End, without completing response output |
| Open / End | Reset, rejected input, cancellation | Release queue; fail waits |
| Integration decoder at envelope boundary | End | Clean message EOF |
| Integration decoder inside envelope/body | End | Truncated-message error |

The initial target defaults are explicit, independently configurable streaming
limits; they do not reinterpret the finite server body limit:

| Bound | Default and enforcement |
|---|---|
| Host output chunk / input queue per stream | 16 KiB each; pause producer/receive credit |
| Connection storage | Existing 16 MiB input/conversion and 16 MiB session/output ceilings |
| Worker storage | Existing shared 128 MiB ceiling, including queued bytes |
| gRPC encoded message payload | 2 MiB, excluding the five-byte envelope; reject before allocating advertised length |
| Decoded message storage | 8 MiB charged allocation budget, including nested objects and temporary copies |
| Messages / cumulative payload per direction | 65,536 messages / 64 MiB; reject before accepting the first excess message |
| Streaming execution duration | 5 minutes from initial metadata by default; explicit route override may shorten or extend it, subject to a stricter server limit |

Expose per-message, cumulative and duration choices through the streaming
integration configuration; expose transport queue sizes only if production
evidence requires tuning. Generated decoding must support allocation accounting
before streaming APIs are released. A consumed framework-owned message and its
decoder scratch are released before advancing; application-retained history is
outside that retention guarantee. The integration must also charge retained
message storage against the worker budget. A single request must not allocate
its advertised decoded bound outside the aggregate ceiling.

## Completion, failure and middleware

Request EOF and streamed response completion are independent. Request EOF allows
output to continue. Streamed response completion closes unfinished input after
terminal consumption, as specified above; both directions retain their input/write
deadlines until completion or cancellation, including simultaneous read/write waits.

The implemented terminal-selection and failure rules above also apply to duplex
execution. The integration chooses gRPC status fields; the host owns their
ordered delivery and the response-write deadline.

Response middleware runs before initial headers. Completion hooks, access logs
and held permits finalize once after terminal consumption or cancellation,
not after headers or the first chunk. Outcome accounting preserves expiry and
transport failures. Generic compression/keep-alive layers must not rewrite
gRPC envelopes or manufacture DATA; streaming integration routes bypass them.
