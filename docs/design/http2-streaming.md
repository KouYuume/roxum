# HTTP/2 streaming contract

Status: the internal output API and production `Reply.stream` writer are implemented.
Incremental input, explicit terminal metadata and the coordination API below remain
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

Callback return waits for accepted DATA to drain, then queues an empty terminal
HEADERS section. The event loop retains its existing terminal-output deadline
and access-log consumption tracking. `maximum_streams` counts active callback
writers; excess writers receive 503. HEAD and bodyless statuses send only headers
and do not enter the callback. Normal cleanup and abandoned fibers release the
writer's quota once.

This callback API currently supports default writer options and uncompressed
output only. Keep-alive payloads, `ends_on_drain`, known-length file writes and
streaming trailers reset the attempted stream. Request input is still bounded
and collected before reads; reading after response commit is unsupported.
Execution expiry, including a previously registered finite expiry response,
resets committed streaming output instead of replacing its headers. A callback
crash resets its stream. Graceful drain keeps the existing process deadline;
there is no streaming-specific terminal status yet. Explicit finish, integration
expiry trailers and completion-hook semantics remain the contracts below.

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

The following Roc signatures specify the target operations; names and module
placement must be checked with the [public API layout](public-api-layout.md)
when exposing them. `Reader` and `Writer` are opaque request capabilities,
never stream IDs or borrowed engine pointers. `Bytes` denotes `List(U8)`.

```roc
read! : Reader => Result([Chunk(Bytes), End], StreamErr)
write! : Writer, Bytes => Result({}, StreamErr)
finish! : Writer, List(Header) => Result({}, StreamErr)
try_read! : Reader => Result([Chunk(Bytes), End, Pending], StreamErr)
try_write! : Writer, Bytes => Result([Accepted, Pending], StreamErr)
wait! : Reader, Writer, [Read, Write, Both] => Result([Readable, Writable, BothReady], StreamErr)
limit_with_trailers! : U64, List(Header) => Result({}, LimitErr)
```

The last operation belongs to request execution and takes a nanosecond duration
anchored at initial metadata, matching existing execution limits. It validates
and copies expiry trailers before committing streaming headers. Capability
operations distinguish closed/cancelled requests, invalid state, rejected input,
limit exhaustion and transport failure; Unavailable covers unsupported transports.

Blocking read/write are conveniences over the nonblocking operations and a
request-scoped wait. A successful write means bounded ownership transfer;
finish waits through transport consumption of terminal output. A callback
return does not implicitly select a gRPC status: the integration must finish
explicitly. Returning with open output is an incomplete response and resets it.

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

Before committing headers, the integration registers bounded generic terminal
fields for execution expiry. The host copies these fields; gRPC owns the status
choice. Expiry after partial output cancels Roc work, drains accepted DATA and
submits that terminal once. It never runs abandoned code or replaces headers with
the finite expiry-response snapshot. The response-write deadline bounds this
drain; if terminal delivery is impossible, reset, then close the connection if
the socket cannot deliver control output.

The serialized owner arbitrates races: transport failure, peer reset and forced
shutdown prevent further output; otherwise the first accepted normal finish or
execution expiry claims terminal selection. Once expiry wins, a later normal
finish cannot replace it. Once normal finish wins, expiry cannot enqueue another
terminal. Write timeout can abort either selection. Graceful shutdown allows
existing streams to finish only until the process drain deadline.

Response middleware runs before initial headers. Completion hooks, access logs
and held permits finalize once after terminal consumption or cancellation,
not after headers or the first chunk. Outcome accounting preserves expiry and
transport failures. Generic compression/keep-alive layers must not rewrite
gRPC envelopes or manufacture DATA; streaming integration routes bypass them.
