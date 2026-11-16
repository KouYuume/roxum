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
HTTP/2 transport socket scheduling. Nonempty records admit and start ready requests; an empty
record blocks on the production poller until outstanding waits finish. Ordinary
records collect ready sockets and timers without blocking at batch boundaries. Responses
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

A separate interactive client exercises real outbound `Tcp.with_origin!` reads.
A loopback upstream withholds its byte until the host reports a registered read
wait, then the production socket hook and readiness event resume the Roc handler.
An immediate HTTP/2 peer completes while that read is suspended. Reset and EOF
cancel two unanswered reads: neither returns to Roc application code, the upstream
observes connection closure, and a held concurrency permit becomes available after
reset. A normal read after reset exercises reused request/wait slots. Normal
completion explicitly discards its upstream connection. All waits must be collected
exactly once and all request memory released. The client synchronizes through
batch-completion and read-registration diagnostics rather than timed sleeps.

This does not test production listener/worker integration, cross-thread resumption,
TCP write/TLS cancellation, file-operation cancellation, or crash isolation. The
loop remains single-threaded and byte-driven; it uses the production wait registry
and readiness backend. The existing `test-http2-wire` socket fixture covers
transport readiness, flow control, and backpressure using synthetic Roc responses.

For compile-only target validation, run `zig build http2-roc-hosts
-Droc-target=x64musl` (or another supported target). This does not run the Roc
application or establish execution coverage on that architecture.
