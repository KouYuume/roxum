# HTTP/2 engine checks

Run `zig build test-http2-engine` for memory, failure, header validation, and output
cursor, stale readiness token, failed owner-initialization, and bounded request-input
ownership/state/allocation-failure unit checks. `zig build test` includes them.

Run `zig build test-http2-wire` for independent hyper-h2 wire checks. The command
creates a local venv under `zig-out/http2-engine/`, installs the hashed dependencies
in `requirements.txt`, and launches the loopback-only fixture. Python 3.9+ with
venv support is required; the first run needs PyPI access. `tools/check.py` includes
this group, and the Linux test image provides `python3-venv`.

The fixture uses the host's kqueue/epoll backend and nonblocking connection owner.
It echoes finite request bodies after input EOF, overwrites its response source
buffer after submission, and writes at most seven socket bytes at a time. Each
connection gets at most 32 steps per turn; runnable work is continued without
waiting for another edge.
The client checks exact response bytes, completion, rejection, and subsequent
connection reuse. It covers output credit 15/16/17, input body limits
4095/4096/4097, header-list accounting 1023/1024/1025, sixteen admitted streams,
reset isolation, and disconnect with a flow-controlled response still retained.
Separate connections hold 15/16/17 requests open, synchronize with PING ACK, and
verify admission counts. Valid counts exercise reset/completion cleanup and slot
reuse. A raw seventeenth HEADERS bypasses the client's admission check; after
SETTINGS acknowledgment, nghttp2 rejects it with PROTOCOL_ERROR GOAWAY and the
last accepted stream ID. Fixture counters verify that it never reaches the
observer, and engine destruction checks that session allocations are released.
Two-connection cases shrink socket buffers and wait for an actual blocked write
before checking that another connection completes. They then verify writable
resumption or abort cleanup, malformed-preface isolation, connection-slot reuse,
and complete responses after TCP write-half closure. Engine destruction checks
allocation cleanup on both successful and interrupted connections.
This is a host-engine contract test, not a supported Roc HTTP/2 listener.

For another supported target, build `zig build http2-engine-fixture
-Droc-target=arm64musl` (or `x64musl`), then run `verify.py` with the resulting
`zig-out/bin/http2-engine-server` on the matching OS/architecture. Build target
variants sequentially: they share the installed executable path.

Request input uses per-stream header/body limits and a shared 128 KiB connection
allocation budget by default. The fixture copies callback data, excludes trailers from the
initial header snapshot, and frees input on reset or disconnect. Wire checks
verify retained path metadata and body fragments across callback batches.

The fixture-only `ROXUM_TEST_HTTP2_INPUT_BUDGET` override selects a smaller budget
for rejection tests. A 2 KiB run verifies stream-local reset, unrelated stream
progress, and capacity reuse after repeated failures. Path diagnostics in responses
contain at most 64 path bytes plus the original length; long-path tests cover
request-header accounting immediately below, at, and above the 1024-byte limit.
