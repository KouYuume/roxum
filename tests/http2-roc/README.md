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
socket scheduling. Nonempty records admit and start ready requests; an empty
record blocks on the production poller until deadline waits finish. Ordinary
records collect ready timers without blocking at batch boundaries. Responses
submitted during that collection are flushed before reading the next record. EOF
disconnects the stream registry before stopping its remaining invocations. Tests
assert decoded statuses and bodies, HEAD representation length, routing errors,
exact completion/reset sets, and cleanup counts. Twenty
repeated calls exceed the sixteen-slot registry capacity over successive turns.

The real `roc_init` and `roc_handle` run with production allocation contexts.
The arena variant uses the production slab allocator and block cache.
Each invocation runs on a production request fiber. On its first wait, live
request allocations move to a detached heap and the shared generation resets;
the allocator referenced by fiber-local context is updated in place. A second
wait reuses that heap. Other requests can finish while these fibers are suspended.
Request live bytes must be zero before normal heap release or reset. Submitted
output survives cleanup even while another request remains suspended. Tracking
additionally verifies the persistent baseline,
canaries, and invalid frees; the fixture's scalar-only model must leave zero persistent
allocations after root cleanup. A pre-execution reset, unsupported method, and invalid
Roc response exercise cancellation and both sides of the invocation boundary.

The normal delayed handler sleeps twice through the real hosted effect. Two other
handlers acquire a concurrency permit and enter a 60-second sleep; reset and EOF
must stop them without waiting for that deadline or returning to application code.
After callback processing, the fixture wakes closed jobs with `client_gone`. The
sleep effect observes the stop before returning to Roc. Cleanup releases held
resources, abandons the detached heap, clears the dead fiber's allocation context,
and finishes its lease before destroying the fiber. No callback resumes a fiber.

Checks require peer progress, input preservation across generations, three detached
heaps, four wait registrations and collections, four resumptions, two poller
wakes, and two cancelled invocations. A probe sees the permit
occupied while its holder waits and available immediately after reset. Normal
completion also returns its permit. Cancelled requests use bulk heap reclamation,
not normal decref/leak markers; aggregate live request bytes must be zero after
all jobs end. The subprocess timeout is shorter than two uncancelled long sleeps.

Every suspension enters the production `scheduler.Waits` registry after the
request heap is detached. `fiber_wait` points to this registry for the fixture's
lifetime. Cancellation signals the registered wait; the ready list removes it
before its fiber resumes or is destroyed. Timer deadlines use kqueue on macOS and
epoll on Linux, including the production wake source and blocking-wait deadline
calculation. No manual `nanosleep` or direct registered-fiber resumption is used.
The registry and all jobs must be empty at shutdown.

Timer completion is now allowed at any batch boundary. The immediate peer in the
same input batch must still finish before the delayed response; later peers have
no ordering guarantee relative to elapsed timers. The real short sleeps retain
their existing scheduling sensitivity if a deadline passes before suspension.

This does not test production listener/worker integration, cross-thread resumption,
socket-effect cancellation, or crash isolation. The loop remains single-threaded
and byte-driven; it uses the production wait registry and readiness backend. TCP/file cleanup hooks
are invoked, but the resource regression here exercises concurrency permits.
The existing `test-http2-wire` socket fixture covers readiness, flow control, and
backpressure using synthetic Roc responses.

For compile-only target validation, run `zig build http2-roc-hosts
-Droc-target=x64musl` (or another supported target). This does not run the Roc
application or establish execution coverage on that architecture.
