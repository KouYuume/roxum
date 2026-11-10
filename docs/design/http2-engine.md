# Internal HTTP/2 engine

The host build includes the nghttp2 1.71.0 protocol library. The internal adapter
in `platform/host/http2/engine.zig` is exercised by a separate socket fixture.
It is not yet connected to the production listener or Roc request scheduler;
applications still use HTTP/1. The [gRPC plan](../plans/grpc.md) records the remaining
milestone 1 work.

## Dependency and replacement boundary

`build.zig.zon` pins the upstream source package and its Zig content hash.
`tools/nghttp2-build.zig` compiles only the 26 protocol-library C sources and
uses the pinned Zig compiler to generate bindings in the build cache. No system
nghttp2, CMake, TLS library, or additional language toolchain is required. The
library is included in `libhost.a` for all three supported targets, including
tracking-allocator builds. Release bundles include `platform/NGHTTP2-LICENSE`.
The expanded platform bundle budget is 13,000,000 bytes, including all supported
host targets and their runtime libraries.

Only the build helper and engine adapter name nghttp2 APIs. The adapter's public
internal types use Zig slices and stream identities; no C pointers, callback
types, or generated declarations are part of the public Roc API. This keeps a
future engine replacement local without creating a general plugin framework.

Keep nghttp2 for now. Reassess `http2.zig` when its protocol behavior, externally
woken streaming, maintenance, and supported compiler/targets meet roxum's needs;
a release label alone is not a migration criterion. Rust is not an adoption
candidate for this host. Monitor nghttp2 upstream security updates and review
version changes together with the source list, generated version header,
package hash, license, and independent-client checks.

## Serialized ownership and I/O

An `Engine` has a stable address until `destroy`. One owner calls its methods;
concurrent use is forbidden. A reentrant call from an observer is rejected.
Observers copy or queue borrowed headers/data and stream notifications; they
must not run application code, block, retain the borrowed slices, or destroy the
engine. A close notification invalidates the stream identity for that engine.
Destroying the engine releases all its resources without notifying observers;
the eventual connection owner must separately cancel its request lifetimes.

`receive` consumes arbitrary input fragments. `output` returns an engine-owned
serialized buffer. The caller acknowledges only bytes actually written using
`consumeOutput`; repeated `output` calls preserve the unsent suffix. No socket,
poller, fiber, or Roc arena is owned by this adapter.

The initial response operation copies a finite body and validates final status
and response headers. Only one response may be submitted per live stream.
An explicit Content-Length must be a single decimal field fitting in `u64`;
ordinary responses require it to match the body length. It is forbidden on 204
and must be zero on 205. HEAD and 304 may carry representation length metadata;
the caller is responsible for its accuracy because that representation is not
necessarily supplied to this adapter.
The DATA provider marks EOF on its last nonempty read, so completion does not
require an extra byte of flow-control credit. Reset/closure releases the copied
body; destroy also releases responses retained by slow readers.

## Bounds and failures

The engine supports at most sixteen admitted streams, with a configurable lower
limit. Header accounting includes name/value bytes plus 32 bytes per field and
is cumulative across initial fields and request trailers. Request body bytes
have a separate cumulative cap. Exceeding either cap resets only that stream.
The observer may have received a valid prefix before rejection and must discard
its queued request state on closure. nghttp2 handles protocol framing and HTTP/2
field validation; a fatal engine failure makes further driving operations fail.

The connection allocation domain counts nghttp2 session allocations, copied
response bodies, and their alignment prefixes against one byte limit. Reallocation
counts both old and replacement allocations during copying; a failed growth
preserves the old allocation. Session creation, input processing, response
submission, and output serialization propagate allocation errors. Partial
initialization and destruction release retained allocations exactly once.
The small engine object and temporary callback-registration object are outside
this limit; the engine's stream table has a fixed size. Observer/application
allocations are outside this domain and require separate bounded admission.

Request input currently uses automatic receive-window replenishment with bounded
finite request sizes. A streaming request reader must replace that with explicit
consumption accounting and aggregate backpressure before this adapter can serve
unbounded or full-duplex requests. Trailers, request deadlines, GOAWAY drain,
production scheduler integration, and corresponding observability are not yet
implemented here. The [transport design](../plans/http2-transport.md) describes
those proposed contracts, not capabilities of this adapter.

## Verification

[Engine checks](../../tests/http2-engine/README.md) combine fault-injected allocator
unit tests with an independent client. They do not substitute for the later Roc
backend/allocator, scheduler-cancellation, malformed-frame fuzzing, Unix listener,
or production shutdown acceptance gates.
