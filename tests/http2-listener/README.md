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
GOAWAY while an upstream read is suspended; that admitted request must finish
before the connection closes and the process terminates successfully.

The test does not claim streaming response or gRPC support. Internal engine/wire
fixtures retain detailed framing, flow-control and allocator fault coverage.

Execution-cap checks run additional TCP and Unix listeners with a 250 ms cap and
10-second body/write timeouts. They verify that an incomplete request never enters
its crashing handler, an accepted upstream connection proves the handler holds its
permit before expiry, cancellation closes that connection and releases the permit, peers
continue, and a committed response can finish after the execution cap. Access
logs retain one timeout for the cancelled handler. Startup rejects zero and the
first duration beyond the nanosecond representation; a valid HTTP/2 cap leaves an
HTTP/1 handler running past that cap unaffected. Existing cases omit the cap and
exercise the default `Unlimited` branch in every backend and allocator mode.
