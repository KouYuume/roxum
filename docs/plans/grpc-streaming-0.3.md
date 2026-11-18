# gRPC streaming for 0.3

Status: implementation plan. The 0.3 release target includes server-streaming,
client-streaming, and bidirectional RPC alongside the existing Unary support.
These capabilities are not implemented or available in 0.2.0. This plan does not
change the current [HTTP/2 contract](../design/http2-engine.md).

## Release scope

Support generated, typed, uncompressed services for all four RPC forms on the
production HTTP/2 TCP and Unix listeners, including a TLS-terminating proxy with
an HTTP/2 upstream. Keep HTTP/1 as the default and preserve finite Unary behavior.

The motivating acceptance service has three operations: subscribe to ordered
updates (server-streaming), submit a sequence and receive a summary
(client-streaming), and exchange numbered requests and acknowledgements before
request EOF (bidirectional). These fixtures establish transport/API semantics;
they are not a new application framework.

Inbound TLS, outbound gRPC, gRPC-Web, reflection, compression, retries, service
discovery, WebSocket, HTTP/3, and new Protobuf schema features are not release
requirements. Request-trailer access and HTTP/1 trailers remain separate work.
No generic application task-spawning API is assumed by this plan.

## Starting point and responsibilities

The [gRPC roadmap](grpc.md) records completed finite HTTP/2 and Unary gates.
The host provides bounded incremental input and output with explicit receive
credit and request-scoped cancellation. `Handler.streaming` receives input,
`Reply.stream` produces output, and `Handler.duplex` coordinates both directions
with scoped callbacks and explicit readiness interests. Generated client-streaming bindings use incremental input. Generated bidirectional services use the duplex handler and share the incremental decoder.

| Layer | Required work |
|---|---|
| Host | Incremental HTTP/2 input/output, explicit receive credit, bounded queues, request-scoped waits, cancellation, half-closes and terminal output. |
| Core Roc API | Typed request-scoped input callbacks, writers and generic response completion; no stream IDs, pointers or gRPC policy. |
| gRPC integration | Incremental envelope parsing, message cardinality, metadata, terminal statuses and the four typed service forms. |
| Generator | Bind schema method streaming flags to the supported service APIs; preserve the existing codec subset. |
| Application | Business policy, authorization and processing; retaining message history is an explicit application choice. |

Follow [platform boundaries](../design/platform-boundary.md),
[ownership](../design/execution-model.md), and [I/O scheduling](../design/io-execution.md).

## Contracts to settle before public streaming APIs

The first implementation PR must record concrete API signatures and state tables
in the relevant design documents. The following are required decisions, not
permission to defer cleanup semantics until integration testing:

- **Output:** distinguish initial headers, writable messages, terminal completion,
  reset and transport failure. Define what a successful write guarantees and
  whether completion waits for output consumption. Terminal status is submitted
  at most once, after queued DATA, and cannot require an extra DATA credit byte.
- **Input:** distinguish a message, clean request EOF, truncated envelope, rejected
  input and cancellation. Account for stream and connection receive credit
  independently; specify when copying, consuming or discarding bytes returns it.
- **Bounds:** specify per-message encoded/decoded bounds, buffered bytes per stream,
  connection and worker, and limits on stream duration or cumulative work. Do not
  silently reinterpret the finite body limit as a per-message limit. Choose
  defaults and configuration exposure explicitly, including compatibility impact.
- **Lifetimes:** no borrowed engine buffer survives a callback or yield. Every
  queued operation and wake validates the connection generation and stream lease.
  Define who frees queued bytes and decoded messages on every terminal path.
- **Duplex execution:** choose how Roc code observes independently progressing
  input and output without deadlocking when a peer stops reading or writing.
  Sequential read/write alternation alone is insufficient. Evaluate scoped
  callbacks or a request-local coordination API before adding concurrency effects.
- **Half-closes:** request EOF must not automatically end pending output. Define
  response completion before input EOF, unread input disposal, and cancellation of
  any remaining handler work. Test both orders and peers that never close.
- **Deadlines and failures:** preserve the deadline anchored at initial metadata.
  The existing finite expiry-response snapshot cannot replace committed streaming
  headers. Define integration-selected terminal status after partial output,
  fallback reset when delivery is impossible, and precedence against normal finish,
  cancellation, write timeout and forced shutdown. Never invoke abandoned Roc code.
- **Middleware:** specify when response stages, access logs and held permits finish.
  Generic compression and keep-alive layers must not alter RPC message framing.

Long-lived streams must release framework-owned messages as they are consumed;
stream duration and total messages must not imply growing retained memory. This
claim excludes data deliberately retained by application logic.

The concrete contracts are recorded in [HTTP/2 streaming](../design/http2-streaming.md).
Its status separates the implemented engine output and production callback writer
and explicit completion/expiry trailers. Generated server-streaming integration
and its production acceptance fixtures are implemented. Incremental production
input, streamed-response half-close cleanup and request-scoped duplex coordination
are also implemented.
[Server-streaming acceptance](../../tests/grpc-streaming/README.md) records
the proxy, cancellation, fixed-budget and memory-sampling workloads; the generated
example also runs from extracted artifacts. Platform-specific results still belong
to the corresponding local/CI verification runs.

## Implementation sequence

Baseline: **14 PRs including this planning PR**, with a planning range of 12–18.
Each implementation PR includes its focused tests, affected contract documentation,
and any necessary generated glue. The table is a dependency sequence, not a
commitment to publish an incomplete capability in an intermediate release.

| PR | Scope | Acceptance before proceeding |
|---|---|---|
| 1 | Adopt the 0.3 scope and this plan. | Separate current behavior, target behavior and deferred features. |
| 2 | Settle streaming API/state contracts and implement bounded incremental engine output. | Independent client receives DATA before completion; partial writes, zero credit, allocation failure and reset release output correctly. Record the input/duplex design sufficiently to avoid an output-only API dead end. |
| 3 | Connect the production scheduler and request-scoped Roc writer to incremental output. | Real Roc writes yield under flow-control/socket stalls; another stream progresses; stale wakes and lease reuse cannot resume old work. |
| 4 | Add generic streamed completion, deadline and shutdown handling. | Headers/DATA/trailers ordering, finish races, expiry after partial output, cleanup and permit/access-log completion have explicit tests. |
| 5 | Implement generated server-streaming integration and incremental message output. | Typed service produces ordered messages and a final status through an independent client; zero-message and error-after-message cases work. |
| 6 | Close server-streaming acceptance on production listeners and proxies. | TCP/Unix/TLS proxy, slow readers, cancellation, bounded memory and compatibility gates pass. Update usage and distribution examples. |
| 7 | Implement bounded incremental input with explicit receive-credit accounting. | Partial and oversized input, allocation failures, discarded bytes and a stalled stream preserve peer-stream progress and aggregate budgets. |
| 8 | Expose request-scoped incremental reads through production execution. | Application receives input before EOF; waits, route limits, cancellation, generations and cleanup work on actual Roc fibers. |
| 9 | Complete half-close and duplex coordination in the core. | Both half-close orders and simultaneous read/write waits terminate correctly; an unrelated stream progresses without connection-lock waits in application code. |
| 10 | Implement generated client-streaming integration. | Independent client sends multiple messages; service consumes incrementally and returns one response. Empty input, malformed final input and early rejection are covered. |
| 11 | Integrate duplex execution with incremental gRPC framing and status ownership. | Response arrives before request EOF; independent input/output pressure and cancellation do not deadlock. |
| 12 | Publish generated bidirectional service APIs and runnable examples. | Independent client exercises interleaving and both half-close orders over TCP/Unix and the TLS proxy. Generated APIs match the schema streaming flags; method forms not yet implemented are explicitly rejected. |
| 13 | Complete cross-mode failure, resource and regression acceptance. | Long streams plateau in framework-owned memory; resets, connection loss, deadline races, GOAWAY and forced drain return resources to baseline. Existing HTTP/1 and Unary checks pass. |
| 14 | Complete distribution, migration and release preparation. | All four RPC forms work from extracted/public-style artifacts outside the checkout; package versions, compatibility, release notes and platform acceptance are complete. |

PRs 2–6 establish server-streaming. PRs 7–10 add incremental receive and
client-streaming; PRs 11–12 complete bidirectional integration. PRs 13–14 close
0.3 acceptance and distribution. Tests for lifecycle failures start in each
owning PR; PR 13 is integration hardening, not their first implementation.

Adjacent rows may be combined if their scope remains reviewable. Do not split
fixture, implementation, generated glue and immediate regression coverage into
separate PRs merely to keep the count small. Conversely, revise the estimate
rather than hiding unresolved design work inside one oversized PR.

Reassess the count after PR 2 (API feasibility), PR 6 (server-streaming acceptance)
and PR 9 (duplex core). Record actual remaining work and reasons for additional
PRs. Do not silently add features to the release target. If one RPC form cannot
meet its gates, explicitly revisit the release scope instead of describing
partial support as completion.

Bounded incremental input and explicit receive credit (PR 7) are connected to
production request-scoped reads (PR 8). `Handler.streaming` receives input before
EOF on real Roc fibers; ordinary handlers still receive complete bodies.
Phase 9 adds streamed-response half-close cleanup and `Handler.duplex` with
independent input/output waits, middleware checks and nonblocking writes.
Phase 10 connects incremental reads to generated client-streaming handlers.
Phase 11 adds duplex framing and terminal status handling on manually registered routes.
Phase 12 connects schema-defined bidirectional methods to typed callbacks and the runnable greeting example.
The next gate is cross-mode failure, resource and regression acceptance (phase 13).

## Shared acceptance matrix

- Exercise all three Roc backends and both allocator modes on production paths.
  Execute macOS arm64 and Linux arm64/x86_64 checks; cross-compilation alone is not
  runtime evidence. Preserve ordinary HTTP/1 and finite Unary regression checks.
- Use independent generated gRPC clients and raw HTTP/2 assertions where client
  libraries hide terminal status, resets or framing. Test fragmented/coalesced
  envelopes, zero-length messages, truncated input, unsupported compression,
  invalid metadata and nearest valid/invalid values around each size/work limit.
- Prove bounded memory with a growing message count at fixed in-flight limits,
  slow readers/writers, allocation fault injection and repeated cancellation.
  Check stream/connection credit separately and observe another active stream.
- Cover cancellation before admission, during input, blocked output and terminal
  completion; deadlines during queueing, partial input and partial output; both
  half-close orders, disconnect, graceful drain and forced shutdown.
- A bidirectional client must wait for a response before sending its next message.
  Also test independent receive/send progress so a lockstep echo cannot be the
  only evidence for duplex support.
- Keep engine/spike tests complementary to production listener tests. Use
  synchronization to establish state; do not infer readiness from a fixed sleep.
  Keep timing-sensitive checks isolated and Python/client dependencies pinned.
- Regenerate ABI glue after boundary changes and follow the complete
  [toolchain matrix](../toolchain.md) before pushing. Validate extracted generator,
  library, integration and platform artifacts together outside the checkout.

## Release completion

0.3 is ready for release preparation only when all four RPC forms meet these
acceptance gates, unsupported features are explicit, and migration/compatibility
checks are complete. Core, integration and Protobuf tool/library versions follow
[versioning](../design/versioning.md) independently; targeting core 0.3 does not
require every package to share that version. Merging or publishing remains a
maintainer operation.
