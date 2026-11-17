# Production HTTP/2 listener checks

Run `python3 tools/check.py --only test-http2-listener` (or
`zig build test-http2-listener`) with the pinned toolchain. The standard runner
builds the current production host and application in all three Roc backends and
both allocator modes. Linux uses the same command through `tools/linux/test.sh`.

The independent client uses the hashed `tests/http2-engine/requirements.txt`
dependencies installed into a dedicated venv by the setup check. Checks run after
setup in the timing lane. Each test starts a real supervisor/worker with two Roc
threads, first on TCP and then on a temporary Unix socket. No fixture host replaces
the connection loop or execution machinery. Each endpoint runs with and without
`--debug`; captured response headers and capture-limit truncation are checked.
Handler crashes must reset only their stream and preserve `crashed` access outcomes;
invalid responses must report `encode_failed`, while peer resets report
`client_closed`.

Cases cover fragmented input while a peer completes, more sequential requests than
the stream-slot capacity, HEAD and routing/application errors, invalid responses,
effect suspension, cancellation of a borrowed TCP connection, and permit recovery.
The upstream accepts before the cancellation probe, proving the handler holds its
permit without racing it. Configured body limits exercise 1023, 1024 and 1025 bytes;
an incomplete body times out while another stream completes. An unfinished header
block expires even before its first field arrives. A response blocked on stream
flow control expires while a bodyless peer completes. Incoming request IDs and
access records are checked. Malformed connections and disconnects must leave peers
usable. Repeated malformed connections must each reach EOF before the next one
connects, covering concurrent readiness scans and close without a later event
masking delayed socket release. Shutdown sends
GOAWAY while two admitted requests on the same connection await upstream data.
Both upstream connections must be accepted before SIGTERM, and data is withheld
until GOAWAY is observed. Both streams must return their distinct payloads, HTTP
200 and exactly one EOF without a reset before the connection closes and the
process terminates successfully.

Callback writer checks stall two Roc writers on stream credit while another
request completes, then verify exact DATA and zero-credit completion. Resetting
more than sixteen writers exercises lease reuse. A configured two-writer quota
returns 503 for the next writer and recovers after cleanup. HEAD and 204/205/304
skip the callback; these finite responses and quota 503 preserve the matched
route in the access log. Unsupported writer options reset only their stream. Two large responses
with ample HTTP/2 credit and a small client socket buffer also leave another
connection responsive, then complete when the client resumes reading. Execution
expiry after commit cannot substitute its registered finite response, and callback
crashes reset only their stream. These cases run on TCP and Unix sockets.
Explicit completion checks include invalid-field retry, empty/exact-credit
trailers, repeated finish and late writes, normal-versus-expiry terminal selection,
accepted DATA draining after expiry, write timeout after normal selection,
held-permit recovery, and graceful/forced
shutdown while completion waits. Forced drain keeps the existing exit-status-1
contract. They do not establish generated gRPC streaming integration. Internal
engine/wire fixtures retain framing, flow-control and allocator fault coverage.

Execution-cap checks run additional TCP and Unix listeners with a 250 ms cap and
10-second body/write timeouts. They verify that an incomplete request never enters
its crashing handler, an accepted upstream connection proves the handler holds its
permit before expiry, cancellation closes that connection and releases the permit, peers
continue, and a committed response can finish after the execution cap. Access
logs retain one timeout for the cancelled handler. Startup rejects zero and the
first duration beyond the nanosecond representation; a valid HTTP/2 cap leaves an
HTTP/1 handler running past that cap unaffected. Existing cases omit the cap and
exercise the default `Unlimited` branch in every backend and allocator mode.

Request-execution checks additionally run without a listener cap. They verify that
elapsed time includes a delayed body and remains monotonic across effect suspension,
zero/already-elapsed limits stop before the next application statement, and a later
larger duration cannot extend a request limit. Expiry cancels a borrowed TCP
connection, releases its permit, and preserves peers. With a listener cap, a Roc
limit cannot widen it. Execution controls report `Unavailable` in initialization and
HTTP/1 requests. All checks use TCP and Unix sockets across the backend/allocator
matrix; exact deadline boundaries remain covered by the internal lease tests.

Metadata-phase checks use a TCP notification and a held permit to prove that Roc
`BeforeBody` runs while the request body is still open. They verify successful
body resumption, reset and deadline cleanup, immediate expiry without returning
to Roc, and exact timeout access outcomes. A 10-second server/input cap distinguishes
the middleware's 500 ms deadline from host defaults. Repeated EOF/parking races
and 16383/16384/16385-byte chunk boundaries cover whole-body `OnChunk` and incremental
streamed reads. Early middleware/fallback replies accept late DATA/trailers, and
an unfinished body still times out after response EOF. Whole/streamed route limits and the configured streamed-read default
exercise 3/4/5 bytes and reject excess before EOF. The large streamed case explicitly
replaces the default with `Unlimited`; only whole reads retain the finite server cap.

Early-response deadline checks configure a 1-second write deadline and a
3-second input deadline. Empty, finite-body, and trailer replies remain open
after their output completes and the write deadline passes, then reset at the
input deadline. Peer requests continue on both TCP and Unix connections.

Expiry-response checks cover immediate termination, replacement without deadline
extension, invalid registration preserving the earlier response and duration,
and normal response commitment winning. A response blocked by flow control must
survive request cleanup and deliver its copied bytes once the client grants
credit. Initialization and HTTP/1 reject registration without retaining Roc values.
Internal tests additionally cover response-size boundaries, allocation failure,
cleanup before queued submission, disconnect/reset, and an I/O reset winning over
queued execution expiry.

Incremental-input checks use a TCP notification from Roc `chunk!` before the client
sends EOF, then count a 256 KiB body without accumulating it in the application.
This exceeds the fixture's 1 KiB finite-body cap and crosses repeated receive
windows. Eighteen resets reuse all stream slots while the callback is asleep with
queued input; an unrelated stream completes each time. Another reset cancels a
reader waiting for more input. TCP/Unix, all three backends and both allocator
modes check worker identity, cleanup and continued peer progress.

Streamed half-close checks hold response credit at 1024 bytes while an unrelated
stream completes, then release it and assert all DATA/trailers precede exactly one
`NO_ERROR` reset for unfinished input. Request EOF first requires no reset. Explicit
finish, implicit callback completion, empty output and expiry trailers preserve
access outcomes, release held permits and reuse more than all 16 stream slots.
Callbacks that wait after finish/expiry must not resume, and workers must not restart.
An engine test splits the terminal write at its last byte and races request EOF
against that suffix; it also checks connection credit and late DATA after closure.
A connection test crosses the input deadline immediately before, at and after its
boundary between terminal consumption and reset serialization: normal streaming
completion stays handled, expiry stays timeout, and finite early replies retain
their input deadline.

Duplex checks run `Handler.duplex` with input transformation and response
middleware. With only 1 KiB of response credit, a 128 KiB upload must still
progress through receive-window updates while an unrelated request completes.
Empty input and 16 KiB chunk boundaries verify counts and terminal trailers;
reset while both directions wait must release the native permit without a
worker restart. The same probes run over TCP and Unix in every backend/allocator.
