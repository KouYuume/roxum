# HTTP/2 engine checks

Run `zig build test-http2-engine` for memory, failure, header validation, and output
cursor unit checks. `zig build test` includes them.

Run `zig build test-http2-wire` for independent hyper-h2 wire checks. The command
creates a local venv under `zig-out/http2-engine/`, installs the hashed dependencies
in `requirements.txt`, and launches the loopback-only fixture. Python 3.9+ with
venv support is required; the first run needs PyPI access. `tools/check.py` includes
this group, and the Linux test image provides `python3-venv`.

The fixture echoes finite request bodies after input EOF, overwrites its response
source buffer after submission, and writes at most seven socket bytes at a time.
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
This is a host-engine contract test, not a supported Roc HTTP/2 listener.

For another supported target, build `zig build http2-engine-fixture
-Droc-target=arm64musl` (or `x64musl`), then run `verify.py` with the resulting
`zig-out/bin/http2-engine-server` on the matching OS/architecture. Build target
variants sequentially: they share the installed executable path.
