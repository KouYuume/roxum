# I/O scheduling

The host uses request fibers on Roc threads and its own kqueue / epoll event loops. Hosted effects that cannot complete immediately suspend the current fiber and register the operation with the event loop. Readiness, timeout, cancellation, or disconnect resumes or terminates that request.

The application can write sequential effectful code without blocking its Roc thread for the entire external operation. This is cooperative scheduling: an arbitrary computation that never reaches a yielding effect is not forcibly interrupted.

Request-local state lives in `fiber.Locals`, including allocation context, body-reader and response-writer capabilities, and debug/log labels. A resumed request must never inherit another request's allocator or handles.

Each suspended request retains its stack and live allocations. Completion, cancellation, and disconnect release those resources exactly once. External resources such as TCP connections and database transactions must be cleaned up when the request ends. Transaction boundaries must not be moved merely to make an API appear pure.

The supervisor and worker topology, thread configuration, and graceful shutdown behavior are described in [deployment](../guides/deployment.md). Memory ownership is specified in [execution and ownership](execution-model.md).

For bodyless requests on Linux, a short TCP head read records that the socket's
currently available input was exhausted. An idle keep-alive connection can then
wait for its next readable notification rather than issuing an immediate empty
read. Buffered pipeline bytes are still processed immediately. Readable or hangup
notifications received while a handler runs or output is pending invalidate that
observation under the connection lock. Body handoff and restoration of a replaced
socket watch also require a fresh probe. Full reads and other operating systems
retain the conservative probe. See the stream-read guidance in
[epoll(7)](https://man7.org/linux/man-pages/man7/epoll.7.html).
