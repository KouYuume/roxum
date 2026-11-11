# HTTP/2 transport decision and lifetime sketch

Status: milestone 0 experiment completed. This is a design input for milestone 1,
not a description of supported roxum behavior. The reproducible
[spike](../../tools/http2-spike/README.md) and its independent-client checks are
isolated from the production build. The parent [gRPC plan](grpc.md) defines scope.

## Engine choice

Use **nghttp2 1.71.0** as the starting engine for core HTTP/2. The spike pins the official
[release](https://github.com/nghttp2/nghttp2/releases/tag/v1.71.0) archive to SHA-256
`c0f55121d88650e4b9227aec28cebaf664d2417ca60fe70be0f8d38829f52116`.
The host build pins the same version's Git source with a Zig content hash in
[`build.zig.zon`](../../build.zig.zon).
The spike establishes the initial transport evidence. The first milestone 1
slice adds [host build integration and an internal engine adapter](../design/http2-engine.md);
production listener and Roc scheduler integration remain pending.

| Candidate | Fit and cost | Decision |
|---|---|---|
| [nghttp2 1.x](https://github.com/nghttp2/nghttp2/tree/v1.71.0) | MIT; C ABI; library-only build needs no external event loop or TLS stack. Incremental byte I/O, custom session allocation, deferred DATA, trailers, and stream reset fit a host-owned scheduler. | Selected and tested on the supported target set below. Maintain the pin, monitor upstream security fixes, and retest upgrades. |
| [nghttp2 v2](https://github.com/nghttp2/nghttp2-v2) | MIT; a complete C rewrite. Its latest release at this assessment is [0.2.0](https://github.com/nghttp2/nghttp2-v2/releases/tag/v0.2.0). | Keep under observation. A new API and less deployment history add adoption risk; no target or lifetime proof was performed here. |
| [Rust h2](https://github.com/hyperium/h2) | MIT; a maintained asynchronous implementation built around Tokio I/O traits. Its [manifest](https://github.com/hyperium/h2/blob/master/Cargo.toml) includes Tokio, bytes, HTTP, and other Rust dependencies. | Not selected: the host should not acquire a Rust toolchain/runtime integration. No binary-size comparison is claimed. |
| [http2.zig](https://github.com/hendriknielaender/http2.zig) | A Zig implementation under active development. | Reassess when the required streaming contracts, interoperability, maintenance, and supported targets are proven; a stable release alone does not trigger replacement. |
| Custom Zig engine | No third-party runtime dependency; direct allocator/scheduler control. | Reject for this scope: roxum would own framing, HPACK, flow control, protocol validation, fuzzing, and security maintenance. Avoid that cost without a demonstrated need. |

The nghttp2 [programmer's guide](https://nghttp2.org/documentation/programmers-guide.html)
describes a byte-in/byte-out engine without socket I/O. A session must not be used
concurrently, and send/receive functions must not be reentered from callbacks.
These constraints fit a serialized connection owner; application fibers resume
outside callback execution. The pinned
[header](https://github.com/nghttp2/nghttp2/blob/v1.71.0/lib/includes/nghttp2/nghttp2.h)
defines the allocator, consume/window, trailer, and reset APIs used by the spike.
Reuse still requires host-side resource limits and adversarial validation.

The downloaded release is 1,995,680 bytes compressed; the spike compiles the 26
C files in the release's library source list, excluding applications and TLS.
ReleaseSafe executables measured in this experiment were 745,200 bytes on macOS
arm64, 5,268,024 bytes for Linux arm64 musl, and 5,420,784 bytes for Linux x86_64
musl. These include Zig, fibers, libc linkage, and debug information according to
the target defaults. They are not incremental production dependency sizes or
comparable stripped sizes. Measure the production archive delta in milestone 1.

## Ownership and scheduling

The following is the implementation direction, not a claim that the existing
HTTP/1 scheduler already supports it:

- A connection owner retains the socket, nghttp2 session, HPACK state, output
  cursor, connection limits, and active-stream registry. Only that owner enters
  the session. Preserve unsent output across partial socket writes before asking
  the engine for another output buffer.
- Each admitted stream owns one request lifetime: fiber, request allocation
  domain, request body queue, response writer, execution deadline, and effects.
  Stream-local failures do not close unrelated streams. Do not reuse HTTP/1's
  connection teardown as request cleanup.
- Callbacks record input, closure, and wakeups. They may submit protocol frames
  as allowed by the engine, but do not resume application code or recursively
  call the engine's send/receive functions. Resume fibers after the callback batch.
- Bound input and output queues per stream and in aggregate per connection.
  Replenish stream receive credit as the application consumes data. Keep
  connection credit accounting separate enough for unrelated streams to progress,
  without exceeding the aggregate admitted memory budget. A slow socket must yield
  to other connections; a stream waiting for credit must yield to other streams.
- Identify pending work by connection/stream generation, not a recycled pointer.
  Reset or disconnect invalidates wakeups, cancels suspended effects, and resumes
  cleanup. Free request memory only after its fiber and pending operations can no
  longer reference it. Callback closure and fiber completion are distinct events;
  release each resource once.

Keep application initialization in the existing single-threaded initialization
phase before request workers begin. Do not initialize an application per HTTP/2
stream. A worker owns each connection throughout its session; any dispatch to
other execution machinery must return protocol operations to that owner.

Drain stops admitting new connections and sends GOAWAY with an explicit
last-accepted stream ID. Existing admitted streams may finish within the shutdown
budget; later streams are refused. On budget expiry, cancel outstanding effects,
finish stream cleanup, flush what the bounded shutdown policy permits, then close
the session/socket. Specify repeated GOAWAY, peer disconnect, and completion races
in milestone 1 tests. The spike does not implement drain or worker coordination.

## Minimum API capabilities

These are semantic commitments for the next design step; spelling and Roc types
remain subject to implementation review.

| Capability | Proposed contract |
|---|---|
| Listener protocol | Add an explicit HTTP/1 versus prior-knowledge cleartext HTTP/2 choice, with HTTP/1 as default. Keep it separate from `Server.Endpoint.Tcp/Unix`. No automatic Upgrade or TLS negotiation in this milestone. |
| Response completion | A request-scoped writer accepts body bytes and one terminal completion with validated final fields. Completion is exactly once; later writes/completions fail. Support empty-body/trailers-only responses. For HTTP/1, reject unsupported trailer operations explicitly until a separate contract exists. |
| Early metadata handling | Make initial request metadata available before body waits. The integration can validate metadata and install a deadline before consuming input or dispatching business logic. Do not wait for `Handler.streaming`'s final callback to do this. |
| Deadline | Capture a monotonic anchor when initial headers are complete. Expose elapsed time and a generic operation to bound execution by a duration relative to that anchor, clamped by server limits. Parsing `grpc-timeout` stays in Roc. If already expired, reject before application work; queueing must not restart the duration. |
| Duplex execution | A request-scoped handler can alternate reads and writes while input remains open. Receive EOF and response completion are independent half-closes. Handles cannot outlive the request. The spike proves the transport shape; a supported Roc duplex API remains a later milestone. |

Resolve deadline/completion races through the owner: once a terminal outcome is
committed, subsequent events cannot change it or complete again. After deadline
expiry, do not start new effects; wake suspended effects for cancellation. This
cannot preempt arbitrary pure Roc computation. Define what the application sees
at effect boundaries and which pending writes are discarded before publishing
these APIs. Keep idle I/O timeouts separate from execution deadlines.

The integration chooses gRPC metadata and final status. Core validates generic
HTTP fields, enforces state/lifetime limits, and transmits or resets the stream.
Host admission or transport failures need not become gRPC statuses. Generic HTTP
compression and middleware must not rewrite RPC framing implicitly.

## Observations and remaining gates

Executed with pinned Zig 0.17.1 and hyper-h2 4.3.0 on macOS arm64 and Linux arm64
musl (Docker). Linux x86_64 musl was cross-compiled, not executed. Both executed
targets passed all checks in the spike README, including cancellation of a blocked
writer and input-window boundary values. Completed and disconnected connections
reported equal created/destroyed fiber counts and zero outstanding tracked
nghttp2 allocations.

This establishes the milestone 0 gate: independent streams share one connection,
one can be cancelled, a response carries trailers, and response data arrives
before request EOF. Each queued output batch ends its DATA provider on the final
nonempty callback with EOF and NO_END_STREAM; after the batch finishes, trailers
can complete independently of DATA credit, even if request EOF arrives later.
The client covers below/at/above the output-window boundary. It also shows the existing stack-switching primitive can
represent those waits. It does **not** verify the complete Roc runtime, its effect
scheduler, request arenas, ABI, worker lifecycle, or production memory bounds.
The spike uses a single connection and bounded blocking socket calls, so it makes
no multi-connection fairness or performance claim.

Before milestone 1 is complete:

- Integrate dependency packaging, license notices, generated C bindings, and all
  supported builds. Map session allocations to connection accounting, not a
  request arena. Bound bytes as well as allocation counts and handle allocation
  failure without assertions.
- Implement the serialized owner in the real readiness scheduler, generation-safe
  wakeups, partial writes, aggregate flow control, admission/header limits, and
  request memory/effect cancellation. Include reset storms and malformed input.
- Implement and test metadata-time deadlines and drain, including already-expired
  queued requests and completion races. Add fuzzing and independent conformance
  coverage; the happy-path engine test is not a security assessment.
- Regenerate any changed ABI glue and run the affected Roc backend/allocator and
  Linux execution matrices. Exercise TCP and Unix listeners and retain HTTP/1
  regressions. The isolated spike does not replace these checks.

The engine build, finite-response adapter, and nonblocking connection owner now
have an independent-client fixture using the host's readiness backend. The next
implementation slice should connect the owner to the production worker connection
table and Roc request scheduler. The production HTTP/1 dispatch path now carries
generation-safe request identities through queueing, claiming, expiry, and
completion; this prerequisite does not yet dispatch HTTP/2 streams. The engine
also exposes initial-header completion independently of request EOF, so the
owner can record admission and deadline metadata before body waits. A bounded
request-lease registry now separates protocol closure from execution completion
and is exercised by the independent-client fixture; production worker dispatch
and effect cancellation remain pending. The Roc request bridge now has a borrowed
metadata entry sharing the HTTP/1 allocation/ownership builder; the metadata type can
represent HTTP/2 as `Http.Version.Http20`. A separate adapter maps completed initial
field sections into that bridge, including authority and split Cookie fields.
A bounded input collector now retains callback bytes under per-stream limits and
a shared connection allocation ceiling, and is exercised by the independent-client
fixture. A consuming bridge now converts completed input into independently
owned Roc request values and releases input and conversion scratch. Production
owner integration and stream body capabilities remain pending. A finite stream
registry now combines input and leases, emits work outside callbacks, and pins
closed running slots until execution cleanup; the independent fixture uses it.
A finite Roc response adapter now normalizes fields and retains response ownership
until copying engine submission; production invocation and response dispatch
remain pending. The owner now submits finite Roc responses using a checked
execution ticket, consumes them on every outcome, and releases conversion scratch
before returning. Independent-client tests exercise this path with synthetic Roc
values. Checked request handoff now validates the claimed ticket and protocol
state before consuming input, and the fixture passes through both Roc ownership
boundaries. A separate byte-driven fixture now invokes the real Roc application
through these boundaries in all backends and allocator modes. It also exercises
request fibers, real hosted sleep waits, detached request heaps, peer progress,
and stopping a sleeping invocation after reset or disconnect, including held
concurrency-permit release and bulk request-memory reclamation. The fixture now
registers suspensions with the production wait registry and drives deadline/wake
collection through kqueue/epoll. Production worker dispatch, HTTP/2 socket-loop
integration, socket-effect cancellation, and cross-thread resumption remain pending.
Trailer/deadline APIs and their
Roc integration can follow in focused changes within milestone 1; do not claim
native gRPC support until the later integration gates pass.
