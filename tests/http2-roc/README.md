# Real Roc HTTP/2 execution checks

Run `zig build test-http2-roc` with the pinned Zig and Roc toolchain. This runs the
speed, dev, and interpreter backends with both arena and tracking allocation. The
complete `tools/check.py` suite includes this group. Linux uses the same command
through `bash tools/linux/test.sh zig build test-http2-roc`.

The test links copied current platform sources against a fixture entry point and
the production hosted ABI exports. Archives and compiled applications live in a
per-run temporary directory; production `platform/targets/` is not modified. The
Python client uses the hashed dependencies from `tests/http2-engine/requirements.txt`
in a separate local venv. An initial run requires access to those packages.

The client sends bounded length-prefixed batches of HTTP/2 bytes over stdin and
parses stdout as HTTP/2. Batches separate execution turns without introducing
socket scheduling. Tests assert decoded statuses and bodies, HEAD representation
length, routing errors, exact completion/reset sets, and cleanup counts. Twenty
repeated calls exceed the sixteen-slot registry capacity over successive turns.

The real `roc_init` and `roc_handle` run with production allocation contexts.
The arena variant uses the production slab allocator and block cache.
Request live bytes must be zero before reset, and output is serialized only after
the request generation ends. Tracking additionally verifies the persistent baseline,
canaries, and invalid frees; the fixture's numeric model must leave zero persistent
allocations after root cleanup. A pre-execution reset, unsupported method, and invalid
Roc response exercise cancellation and both sides of the invocation boundary.

This does not test production listener integration, fibers, yielding hosted effects,
concurrent application work, or crash isolation. Those remain separate work. The
existing `test-http2-wire` socket fixture covers readiness, flow control, and
backpressure using synthetic Roc responses.

For compile-only target validation, run `zig build http2-roc-hosts
-Droc-target=x64musl` (or another supported target). This does not run the Roc
application or establish execution coverage on that architecture.
