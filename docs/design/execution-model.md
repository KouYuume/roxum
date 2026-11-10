# Execution and ownership

## Root handler

`roc_init()` returns an erased callable capturing the model and router. The host retains one root ownership for the worker lifetime. Before each request it retains the callable through generated glue; `roc_handle` consumes that invocation ownership. The returned response belongs to the host until encoding, sending, and generated-glue cleanup finish. Dropping the root must also drop its captures.

Never implement Roc reference counts by hand. Contract tests check zero, one, and repeated calls, missing retains, final capture cleanup, zero live request allocations, and return to the persistent allocation baseline.

## Allocation domains

Persistent allocations outlive requests; request allocations last until their values are released or the request is cleaned up. The allocation prefix stores size and domain/generation metadata immediately before the user pointer. Its size is `max(alignment, 2 * sizeof(usize))`; padding precedes the metadata at larger alignments.

Only allocation chooses a domain from the active context. Reallocation and deallocation use the pointer's recorded domain, never the current execution phase. Reallocation preserves domain and generation. A stale request generation detects use after reset. Contract tests exercise power-of-two alignments 1, 2, 4, 8, 16, and 32.

The production request allocator reuses freed capacity. Small values up to 1 KiB with alignment at most 16 use slabs; empty slabs return their pages to the block cache. Larger allocations use page-rounded blocks. Blocks above the cache size or alignment limits return directly to the backing allocator. Reset releases remaining live allocations and advances the generation; deinit releases caches as well. A cloned worker starts with an independent empty cache.

Streaming cleanup must not retain all previously transmitted chunks. Detaching a request transfers its live allocations, including slabs that contain live values. Tracking mode additionally checks real frees, canaries, and live counts.

## Request-local state

The allocator ABI cannot accept an additional request argument. On a request fiber, allocation context, body tokens, writer capabilities, and debug labels belong to `fiber.Locals`. The current fiber is recovered from the stack location. Thread-local fallback state is for execution outside a fiber, such as initialization.

A suspended fiber can resume on another thread. Do not cache a thread-local address across a yielding effect: the resumed request could otherwise access its former thread's state. Request-local state must remain valid through response cleanup. Do not expose this implementation mechanism as implicit application state; pass transaction and resource capabilities explicitly.

## Scheduling and connection ownership

A supervisor retains the listening socket and restarts workers; accepted connections belong to workers. TCP and filesystem Unix listeners use the same descriptor handoff. A worker that creates a Unix listener transfers its path and filesystem identity with the descriptor; subsequent workers reuse it. The supervisor removes the owned pathname after shutdown, only if its identity still matches. Existing paths are never removed to make binding succeed. The operator controls the parent directory and handles stale paths after an interrupted ownership transfer or a killed supervisor. A worker shares a poller, connection table, wait registry, and work queues across its threads. The acceptance thread handles admission, deadlines, and shutdown without invoking Roc. Roc threads process requests and ready fibers.

Connection locks protect event processing and completion. Queued requests carry
an immutable connection slot, connection generation, per-slot dispatch sequence,
and queue timestamp. A Roc thread validates and claims that identity under the
connection lock before admission or request execution; duplicate and stale jobs
are discarded. Completion and failure paths validate the identity under the same
lock before changing connection state. The sequence advances for each request,
including keep-alive requests, survives connection-slot reuse, and never wraps:
exhaustion closes the connection instead of issuing an older identity.

Queue expiry reads the job's immutable timestamp, without looking up mutable
connection state while holding a queue lock. After removal, it validates the
identity and unclaimed state under the connection lock before rejecting a request.
This avoids queue-to-connection lock ordering against dispatch's
connection-to-queue order. HTTP/1 keeps a claimed connection slot pinned until
completion; this does not yet provide independent HTTP/2 stream lifetimes.
While a request is dispatched, its handler does not hold the connection lock. A request starts with the shared request heap; its first suspension detaches live allocations into its own heap so the shared heap can serve another request.

Initialize Roc on one thread before creating the remaining Roc threads. The compiler runtime's lazy process-wide initialization must not race. Fiber switching uses host register-save routines. Socket waits use one-shot poller registration; timeout and readiness compete to resume a wait exactly once. DNS resolution runs on dedicated threads, with the request fiber waiting on a pipe under a deadline.

## Failure and shutdown

A Roc crash on a request fiber abandons that fiber, releases its heap, and closes borrowed TCP resources. Before the response head, the host returns 500 with connection close; after the head, it closes without attempting another response. Other requests in the worker continue.

A crash outside a request fiber, host panic, or stack overflow terminates the worker. All of that worker's connections are lost; the supervisor can restart it. Stack overflow is fatal because host or libc code may hold locks.

The event loop owns final connection closure. Lingering close shuts down writes and drains unread input under bounded byte/time limits to reduce resets that could discard the response. This differs from unread-body cleanup for keep-alive, which only skips data already buffered.

See [streaming lifecycle](streaming.md) for response cancellation and [deployment](../guides/deployment.md) for limits and draining. Validation includes `zig build test-contract`, `zig build test-tcp`, and Linux `zig build test-tsan`, as well as E2E tests across backends and allocator modes.
