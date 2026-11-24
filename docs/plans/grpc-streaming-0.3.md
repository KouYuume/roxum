# gRPC streaming acceptance for 0.3

Core 0.3 and roxum-grpc 0.2 support all four uncompressed RPC forms on
production HTTP/2 TCP and Unix listeners, directly or behind a TLS proxy.
The [gRPC roadmap](grpc.md) records responsibilities and excluded features.

## Implementation and evidence

| Capability | Contract or verification |
|---|---|
| Incremental input and output | [HTTP/2 streaming contract](../design/http2-streaming.md) defines receive credit, writer readiness, request lifetimes, half-close, expiry and middleware ordering. |
| Generated service registration | [gRPC integration](../../integrations/roxum-grpc/README.md) describes the callback and limits selected by each schema method. |
| Failure and resource recovery | [Production fixtures](../../tests/grpc-streaming/README.md) exercise partial envelopes, blocked output, independent peer progress, memory bounds, cancellation and drain. |
| Public-style artifacts | [Distribution check](../../tests/release/verify_grpc.py) installs the extracted generator, fetches all three Roc bundles and calls all four RPC forms outside the checkout. |
| Package compatibility | The [migration guide](../guides/migrating-to-0.3.md) records version selection, application changes and API comparison limits. |

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

Each decoder has an 8 MiB allocation budget per decoded
message, including nested values and temporary copies, with retained decoder
storage charged against the shared worker ceiling. The
[decoder heap](../../platform/host/allocator/decode_heap.zig) charges value buffers
and their allocation headers to both ceilings. The fixed heap descriptor counts
only toward the worker ceiling. Its tests cover allocation
headers, overlapping buffers during growth, competition with transport storage
and request cleanup. The [host allocation context](../design/execution-model.md#allocation-domains)
routes fresh allocations inside a decode scope to the message heap. Reallocations
and frees follow the original owner even in a later callback.
All four RPC forms copy the payload into the heap before invoking the codec,
including when a decoder retains its input. Failure to create the heap or
copy the input yields `RESOURCE_EXHAUSTED`. Unary, server-streaming and
client-streaming handlers also supply a finite error response for allocation
failure inside the codec, before output starts. A bidirectional handler supplies
the unsent suffix of an already started envelope and terminal status fields. On codec exhaustion
the writer drains that suffix under flow control and sends `RESOURCE_EXHAUSTED`.
The [distribution check](../../tests/release/verify_grpc.py) exercises all four
forms against the extracted packages.

0.3 is ready for release preparation only when all four RPC forms meet these
acceptance gates, unsupported features are explicit, and migration/compatibility
checks are complete. Core, integration and Protobuf tool/library versions follow
[versioning](../design/versioning.md) independently; targeting core 0.3 does not
require every package to share that version. Merging or publishing remains a
maintainer operation.
