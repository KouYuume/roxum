# HTTP/2 streaming contract

Status: production `Reply.stream` output, explicit terminal metadata and execution
expiry trailers are implemented. Incremental input and the coordination API below remain
the implementation target for [0.3](../plans/grpc-streaming-0.3.md).

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

Callback return implicitly completes with empty trailers unless the writer already
finished explicitly. Both paths drain accepted DATA and wait until the terminal
HEADERS have been consumed by socket writes. Protocol closure alone is not
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
options reset the attempted stream. Request input is still bounded
and collected before reads; reading after response commit is unsupported.

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

## Target request-scoped API and duplex coordination

The following signatures specify target incremental-input/duplex operations.
Names and module placement must be checked with the [public API layout](public-api-layout.md)
when exposing them. `Reader` and `Writer` are opaque request capabilities,
never stream IDs or borrowed engine pointers. `Bytes` denotes `List(U8)`.

```roc
read! : Reader => Result([Chunk(Bytes), End], StreamErr)
write! : Writer, Bytes => Result({}, StreamErr)
try_read! : Reader => Result([Chunk(Bytes), End, Pending], StreamErr)
try_write! : Writer, Bytes => Result([Accepted, Pending], StreamErr)
wait! : Reader, Writer, [Read, Write, Both] => Result([Readable, Writable, BothReady], StreamErr)
```

The implemented completion and expiry operations above remain request-scoped.
The target read/write capabilities distinguish closed/cancelled requests, invalid
state, rejected input, limit exhaustion and transport failure; Unavailable covers unsupported transports.

Blocking read/write are conveniences over the nonblocking operations and a
request-scoped wait. A successful write means bounded ownership transfer;
explicit finish waits through transport consumption of terminal output. The gRPC
integration must finish explicitly with its status; generic callback return only
provides an empty terminal section, not a successful gRPC status.

Duplex handlers use a coordination loop: try both interested directions, then
wait for either to progress. A pending write retains no caller bytes; the loop
can continue processing input before retrying that write. Read and write
readiness are independent and level-triggered; input EOF remains readable until
observed. Output completion removes write interest. Waiting on an already
completed direction is an error. No general task-spawning API or mandatory
read/write alternation is introduced. A handler that elects to block on write
alone still accepts that its own input processing can stall.

Host waits carry a connection generation and stream lease; validate both before
every operation and wake. Reset cancels all waits once. Capabilities become
invalid after callback scope; retaining them must not extend resource lifetime.

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

## Target completion, failure and middleware

Request EOF and response completion are independent. Request EOF allows output
to continue. Response completion first cancels remaining handler work and
discards unread input with connection-credit recovery; after terminal output is
consumed, reset the unfinished request side rather than waiting indefinitely for
peer EOF. The lease remains reserved until protocol closure. Both orders keep
their own input/write deadlines.

The implemented terminal-selection and failure rules above also apply to duplex
execution. The integration chooses gRPC status fields; the host owns their
ordered delivery and the response-write deadline.

Response middleware runs before initial headers. Completion hooks, access logs
and held permits finalize once after terminal consumption or cancellation,
not after headers or the first chunk. Outcome accounting preserves expiry and
transport failures. Generic compression/keep-alive layers must not rewrite
gRPC envelopes or manufacture DATA; streaming integration routes bypass them.
