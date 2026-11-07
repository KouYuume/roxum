# Platform boundary

The platform provides the smallest typed capabilities needed to interact with the outside world. Pure parsing, validation, routing, encoding, and application decisions belong in Roc. Existing Zig code or convenience alone is not a reason to add a hosted effect.

A hosted API is appropriate when it needs an operating-system resource, external I/O, time, randomness, or a host-owned lifetime. The host owns sockets, files, connection pools, deadlines, scheduling, and HTTP framing. Roc receives typed capabilities rather than raw pointers.

Applications use `Handler`, `Router`, `Reply`, and the public integration APIs. Internal request-body tokens and response-writer handles remain tied to the active request. They cannot become general-purpose socket access.

Keep effects at boundaries and decisions in pure functions. An effectful call uses `=>` and the `!` naming convention; a pure transformation uses `->`. See the [Roc coding rules](../../roc_coding_rules.md).

Changes to a hosted capability must preserve ownership, cancellation, and resource cleanup on success, failure, disconnect, and shutdown. Regenerate and verify ABI glue whenever its types change, and rebuild the host and application together.
