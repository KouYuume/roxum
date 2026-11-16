# HTTP/2 transport decision

Status: milestone 0 experiment completed; finite production HTTP/2 and Unary gRPC
are implemented. This record preserves the engine decision and isolated spike
evidence. Current behavior and lifetime contracts live in the
[engine design](../design/http2-engine.md); acceptance and future streaming gates
are tracked in the [gRPC plan](grpc.md).

## Engine choice

Use **nghttp2 1.71.0** as the starting engine for core HTTP/2. The spike pins the official
[release](https://github.com/nghttp2/nghttp2/releases/tag/v1.71.0) archive to SHA-256
`c0f55121d88650e4b9227aec28cebaf664d2417ca60fe70be0f8d38829f52116`.
The host build pins the same version's Git source with a Zig content hash in
[`build.zig.zon`](../../build.zig.zon).

The production dependency, replacement boundary, and upgrade checks are documented
in the [engine contract](../design/http2-engine.md). The alternatives below record
the milestone 0 assessment, not a continuously updated market comparison.

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
comparable stripped sizes. For the production package budget, see the engine contract.

## Spike evidence and limits

Reproduce the experiment using the [spike instructions](../../tools/http2-spike/README.md).

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

## Implementation boundaries

The host owns sockets, serialized engine access, resource budgets, stream leases,
and cancellation. Roc integrations own Protobuf, RPC metadata, timeout parsing,
and final status. Engine callbacks only record or copy work; application code runs
outside them. These responsibilities remain independent of the selected engine.

The [finite acceptance record](http2-finite-acceptance.md) covers the production
scheduler, TCP/Unix listeners, resource recovery, metadata-time deadlines and drain.
The [Unary integration](../../integrations/roxum-grpc/README.md) adds generated
services and independent-client acceptance. Incremental receive credit, response
streaming and duplex execution require the separate gates in the gRPC plan;
the spike's duplex exchange does not make them supported application APIs.
