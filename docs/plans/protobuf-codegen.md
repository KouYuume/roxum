# Protobuf codec and generator assessment

Status: milestone 2 is complete for the documented `proto3-v1` subset.
The [pure Roc wire library](../../libraries/roc-protobuf/README.md) provides bounded
primitive reads/writes and unknown-field skipping. The
[protoc plugin](../../tools/protoc-gen-roc/README.md) generates singular
codecs for all 15 proto3 scalar types with implicit or explicit `optional`
presence, plus empty messages. Native `F32`/`F64` conversion is verified, including
signed zero and NaN canonicalization. Optional scalar fields use
`[Absent, Present(T)]`, with present-default values retained on the wire.
Singular message fields are supported with explicit
presence and duplicate-occurrence wire merge, with or without explicit `optional`.
Repeated scalar and message fields preserve order
and share collection-entry limits. String/byte payloads also share materialization
limits. Numeric and boolean lists accept packed and unpacked input.
Proto3 enums support nominal numeric values, aliases, unknown numbers, optional
presence, and repeated packed/unpacked fields. Maps use typed dictionaries with
entry defaults, last-key-wins replacement, and shared wire budgets. Real oneofs
use tagged selections with an explicit unset state, message merge, and case
replacement. Recursive schemas use co-located cyclic components and bounded
encoder traversal. Standalone distribution and the matched tool/library contract
complete the packaging gate. Unary RPC is covered separately by the
[gRPC integration](../../integrations/roxum-grpc/README.md).
A [handwritten layout fixture](../../tests/protobuf-layouts/README.md)
checks bounded self-recursion, mutual recursion, recursive lists, and imported
payload records on the pinned compiler. The generator retains fully qualified
message identities, emits nested declarations with enclosing names
concatenated, and supports imports when the complete dependency closure is
explicitly selected in one invocation. Case-insensitive output collisions fail
before generation. Generated scalar codecs expose `decode_into` and
`encode_into` for existing reader/writer composition, with wire merging and
shared-budget fixtures. Fully qualified message references resolve through
direct/public imports; generated message codecs share reader budgets
and bounded child output.
This records milestone 2 of the [gRPC plan](grpc.md), following
[finite HTTP/2 acceptance](http2-finite-acceptance.md).

## Inventory and direction

Inventory date: 2026-11-13. The following sources were checked:

| Source | Observation | Consequence |
|---|---|---|
| [Roc Awesome, current list](https://github.com/lukewilliamboswell/roc-awesome/blob/8c6fbdd0493cd7817ef0a5ad2924aa862c2150ba/README.md) and [legacy list](https://github.com/lukewilliamboswell/roc-awesome/blob/8c6fbdd0493cd7817ef0a5ad2924aa862c2150ba/LEGACY_ROC.md) | No Protobuf codec or `protoc` generator was listed. Serialization packages listed for other formats are not Protobuf implementations. | No listed dependency can replace this milestone. |
| GitHub repository searches below | No Roc Protobuf implementation was found by the targeted queries. Broader name searches also returned unrelated projects. | This is a bounded inventory, not proof that no implementation exists. Reassess if a concrete candidate appears. |
| [Existing gRPC probe](../../tests/grpc-probe/README.md) | Uses fixed serialized bytes and the native client's raw-byte API. | Reuse its transport test approach, not its fixed bytes as a codec. |
| [Protobuf plugin interface](https://protobuf.dev/reference/other/) | A standalone program exchanges generator request/response messages with `protoc`. | Reuse the schema compiler and descriptor model; do not build another `.proto` parser. |

The targeted searches were `protobuf language:Roc`, `protobuf topic:roc-lang`,
and `protoc-gen-roc` using `gh search repos`. These queries returned no
repositories at the inventory date. Search indexing and package lists are
incomplete; there is no candidate whose compiler compatibility, coverage,
license, or decoder limits have been validated by this assessment.

Proceed with a pure Roc library under `libraries/` and a separate build-time
generator. Neither requires a new hosted effect. Generated message codecs must
work without importing roxum; service registration belongs to the gRPC
integration. This follows the [platform boundary](../design/platform-boundary.md).

Use a Python `protoc` plugin with the official Python Protobuf descriptor types
as the initial implementation direction. Python is already used by repository
tooling, and this avoids bootstrapping descriptor decoding in Roc before its
codec exists. The plugin reads `CodeGeneratorRequest` and writes
`CodeGeneratorResponse`; it emits Roc source, not native runtime code. See the
[plugin schema](https://github.com/protocolbuffers/protobuf/blob/main/src/google/protobuf/compiler/plugin.proto).
This choice is for build tooling only and does not add Python to deployed apps.

The scalar pilot pins `protoc` 33.5 and the official Python Protobuf 6.33.5
universal wheel, including the independent reference implementation. Its
[toolchain instructions](../../tools/protoc-gen-roc/README.md#toolchain-and-generation)
record artifact hashes and licenses. These dependencies are build-time only.
Validate dependency changes on the supported development/test environments.
The codec package and generator are versioned together and distributed under the
[standalone compatibility contract](../../libraries/roc-protobuf/DISTRIBUTION.md).

## Initial schema target

The table is the milestone 2 target, not current support. Incremental generators
must reject features they cannot yet implement, identifying the file and symbol;
they must not emit plausible but incomplete codecs. Interpret descriptors, not
source spelling. The baseline is [proto3](https://protobuf.dev/programming-guides/proto3/)
with [field presence](https://protobuf.dev/programming-guides/field_presence/).

| Feature | Proposed contract |
|---|---|
| Integers and booleans | Cover all proto3 integer scalar types with their declared width, signedness, and wire encoding. Keep numeric conversion separate from raw varint parsing. |
| `float`, `double` | Preserve IEEE wire behavior, including signed zero, infinities, and NaNs. Prove the required conversions on the pinned Roc compiler before selecting the public representation. |
| `string`, `bytes` | UTF-8 validated strings and arbitrary byte lists; length checks precede copying. |
| Singular scalar and enum fields | Default values for implicit presence; explicit presence distinguishes absent from present-default. |
| Messages | Explicit presence for singular messages; duplicate occurrences merge. Nested definitions and imported types use fully qualified descriptor identities. |
| Repeated fields | Preserve element order; accept packed and unpacked encodings for packable fields, including multiple segments. |
| Maps | Apply protobuf entry defaults and last-entry-wins for duplicate keys. Roc representation must preserve the declared key type. |
| Enums | Preserve unknown numeric values and support declared aliases; do not conflate an unknown value with zero. |
| `oneof` | Explicit unset state and one active case. Repeated occurrences of the same message case merge; switching cases replaces the prior case. Synthetic oneofs for proto3 optional fields are presence metadata, not user-facing unions. |
| Recursive schemas | Target bounded recursive values. Compile self-recursive and mutually recursive fixtures before committing to generated Roc type layouts. |
| Services | Codec generation can process messages in a file containing services without generating RPC bindings. Opt-in finite Unary service generation is available through the roxum-grpc integration mode. |

Proto2 schemas, editions, extensions, custom-option behavior, JSON/text codecs,
and special APIs for well-known types are outside this initial target. Reject
unsupported dependencies in the generated type graph as well as unsupported
top-level declarations. Do not silently ignore options that change wire or
presence behavior. Ordinary source metadata and options for other languages
need not change codec generation. Define the accepted option set in the plugin
validation tests before enabling generation.

Well-known types require an explicit supported import policy and fixtures before
acceptance; a familiar name is not evidence that its behavior is implemented.
Do not promise reflection, `Any` resolution, or special timestamp handling.

## Wire and resource contracts

Use the [encoding specification](https://protobuf.dev/programming-guides/encoding/)
for field tags, varints, fixed-width values, and length-delimited payloads.
The initial decoder consumes one complete message from a bounded byte list.
The gRPC integration will remove message envelopes before calling it; neither
HTTP DATA boundaries nor the five-byte gRPC prefix belong in the codec.

Proposed unknown-field policy: validate and skip unknown fields, without
retaining them for re-encoding. Document this loss of unknown data prominently;
the initial library is not a lossless schema-evolution relay. This does not apply
to unknown enum numbers in known fields, which remain represented. Unknown
groups still require bounded, matching start/end handling; rejecting proto2
schemas does not make arbitrary incoming wire bytes safe to skip.

The decoder must reject truncated values, overflowing varints, invalid tags and
wire types, invalid UTF-8 in known strings, mismatched groups, and configured
limit violations with a typed error. Decide and test how known fields with a
different wire type are skipped as unknown, rather than coercing them. Accept
valid non-minimal varints and legal reordered/duplicate fields; do not require a
canonical byte representation. Never use a crash for malformed external input.

Carry one shared budget through nested messages, packed fields, maps, and skipped
unknown values. The [wire reader contract](../../libraries/roc-protobuf/README.md#reader-contract)
defines finite defaults, exact units, and boundary tests for the primitives;
schema decoders must extend their use to packed fields, maps, and merge behavior:

- Maximum input bytes and maximum length-delimited field bytes.
- Nesting depth, counting both messages and unknown groups.
- Total field occurrences and decoded collection entries, including duplicates
  that overwrite earlier values.
- Cumulative materialized bytes, including values later replaced during merge.

Charge before copying or growing collections; check lengths against remaining
input using overflow-safe arithmetic. Bound temporary storage and repeated work,
not just the final returned value. These are logical codec limits, not a claim
to measure every allocator byte; host request memory limits remain independent.
The wire foundation tests lower, exact, and upper boundaries. Its writer bounds
accumulated output; generated scalar encoders can append to an existing bounded
writer. `write_message` adds buffered length-delimited composition bounded by
the remaining output capacity. Generated encoder scopes share depth and visited-message limits. Standalone packaging and independent interoperability establish codec reuse,
not gRPC service support.

Packed varint, fixed32, and fixed64 payload readers share entry limits and
containing-reader bounds without increasing message depth. Generated repeated
numeric and boolean fields accept mixed packed/unpacked input and encode
according to the `packed` option (packed by default). Typed packed readers use
the same signed, ZigZag, boolean, and IEEE conversions as singular fields.

## Implementation slices and gates

1. **Wire primitives and budgets (implemented).** The pure library foundation covers varints,
   tags, fixed-width words, checked length slices, unknown-field skipping, and
   shared budget accounting. Tests cover empty/truncated inputs, every varint width
   transition, tenth-byte overflow, field-number and wire-type boundaries,
   group matching, and all limit boundaries. The unit suite, independent Python
   wire comparison, and pinned Roc fuzz target cover this slice. It contains no
   generator or host changes.
2. **Descriptor-to-Roc feasibility.** Introduce the pinned plugin toolchain and
   generate a small message with the already supported scalar subset. Check
   output with the pinned Roc compiler across all backends. Resolve naming
   collisions, imports, recursive types, float representation, and presence
   layouts with fixtures before expanding the supported subset. Unsupported
   descriptors must fail before any generated output is accepted.
3. **Schema semantics.** Expand codecs and generation to the target matrix,
   including merge behavior, packed fields, maps, enums, and oneofs. Keep
   explicit unsupported-feature diagnostics as the matrix grows.
4. **Interoperability and packaging.** Exchange generated values with an
   independent Protobuf implementation in both directions. Test noncanonical
   valid input, malformed input, resource limits, and schema rejection. Pin
   reference fixtures and dependencies, verify deterministic generation, and
   document the package/tool compatibility contract.

Each slice may require more than one focused PR. Slice 2 has scalar generation,
including nested declarations and explicit multi-file import closure, with
collision and deterministic-output fixtures. Package names remain schema
identities rather than Roc namespaces; ambiguous flattened module names are
rejected. Generated scalar `decode_into`/`encode_into` functions preserve reader
scopes, existing merge values, and accumulated writer capacity. Handwritten
parent scope drivers compare repeated child occurrences with official Python
message decoding and exercise shared limits. Generated acyclic message references, recursive merging
through finite schema levels, and buffered length-delimited encoding have interoperability fixtures.
Cyclic schema components are emitted as co-located nominal definitions with
boxed singular edges, building on the handwritten layout fixture. Generated
recursive fixtures additionally validate composite wire semantics and encoder
traversal limits.
Scalar representation, including native floats, bounded UTF-8 conversion, and
optional presence, is implemented. Before
expanding the generator, resolve compiler limitations with evidence rather than
silently changing the compiler pin or moving pure codec logic into the host.

Milestone 2 acceptance requires generated code to compile with the pinned
compiler and the advertised schema subset to pass independent interoperability
and negative tests. The checks below provide this evidence. Compare values and presence rather than encoded-byte
identity; check signed zero and NaN semantics explicitly instead of using an
ordinary floating-point equality assertion. Unary integration acceptance is
recorded separately in the [gRPC plan](grpc.md).

## Evidence and limits of this assessment

The wire foundation has module boundary tests and an application fixture that
compares primitive reads/writes and skips with an independent Python wire parser
across the Roc backend/allocator matrix. Arbitrary-byte fuzzing checks progress,
read/skip agreement, and varint round trips. Structured nested-message fuzzing
checks scope boundaries and cumulative budgets against a separate counter model.
See its [verification commands](../../libraries/roc-protobuf/README.md#verification).
The pinned fuzz runner supports macOS arm64 and Linux x64, not Linux arm64;
the latter still runs the module and differential tests.
The scalar pilot adds generated Roc and Python fixtures, pinned build tools,
and value comparisons with official Python Protobuf for its advertised subset.
The `test-protobuf-codegen` group covers defaults, duplicates, unknown/wrong-wire
fields, malformed inputs, resource bounds, schema rejection, and deterministic
output. It compiles empty and scalar record types across the backend/allocator
matrix. Scalar interoperability also covers signed limits, 32-bit truncation,
ZigZag, nonzero booleans, valid/invalid UTF-8, and exact non-NaN IEEE patterns.
NaNs are compared by class because the pinned Roc `to_bits` API canonicalizes
their payload and sign. Scalar fuzzing checks parser progress, canonical
round trips, and exact output limits. Optional scalar fixtures verify all 15
payload layouts across the backend/allocator matrix, compare Python `HasField`
with direct Roc presence/value views, and check present defaults, clearing,
duplicates, wrong-wire skipping, malformed values, and cumulative/output bounds.
Synthetic oneof metadata is validated separately from real oneof selections. The reference
implementation's overlong-tag limitation is recorded in the [generator verification notes](../../tools/protoc-gen-roc/README.md#verification).
These checks establish the advertised codec subset together with the composite
and distribution fixtures below; the fixed-byte gRPC probe still supplies no
generated service bindings.

The separate `test-protobuf-layouts` group checks construction, cross-module
traversal, retained originals after child replacement, and request-lifetime
cleanup for those candidate layouts across all backends and allocators. Input
selects depth and heap-backed payloads at runtime. Closed-form Python assertions
cover node/payload summaries, depth and input boundaries, and repeated deep
requests; tracking mode requires one allocator success marker per request.
These layout checks complement the generated recursive codec checks below.

## Enum representation and codecs

The handwritten layout fixture verifies a nominal `I32` wrapper across module
boundaries, including presence and list fields. The generator uses this layout
for proto3 open enums. Top-level, nested, and imported declarations share the
message identity and collision checks. Aliases require `allow_alias`; unknown
numbers survive decode and encode. Generated message fields use the enum codec
for implicit, optional, and repeated values, sharing existing wire budgets.
Python interoperability covers values, presence, mixed packing, merge, malformed
input and resource limits. Enum naming and composition APIs are documented in
the generator guide. Recursive component behavior is described below.

## Map representation and codecs

The handwritten layout fixture verifies `Dict` with all six Roc key types
needed by proto3 maps: `I32`, `I64`, `U32`, `U64`, `Bool`, and `Str`. Imported
message values, enum values, strings, and byte lists are observed across modules,
including retained originals after duplicate-key replacement. The generator uses
these typed dictionaries while preserving each schema key's wire encoding in its
synthetic entry codec.

Validated map entries start from defaults; duplicate keys replace complete
values. Message occurrences merge within an entry, while separate entries replace
the previous message. Shared budgets charge every decoded entry and its fields,
including overwritten keys and values. Bounded writers compose entry payloads;
dictionary order does not imply deterministic serialization. The codegen fixture
compares all legal key encodings, defaults, merge, unknown fields, malformed input,
and resource/output limits with Python Protobuf. Generated helper identities
participate in the existing import, naming, and collision rules. See the
[map API and wire contract](../../tools/protoc-gen-roc/README.md#maps).

## Oneof representation and codecs

Real oneof groups use a closed tag union in the containing message record, with
`Unset` and one payload tag per member. Generated codecs and application-side
matching verify all scalar layouts, imported open enums, and message payloads on
the pinned compiler. Each group has one active case; selected defaults remain
present on the wire. Synthetic optional groups retain the existing presence API.

Repeated occurrences of a message case merge while that case remains selected.
Switching cases replaces the previous payload; switching back starts from defaults.
Unknown/wrong-wire fields leave the selection alone. Shared wire budgets remain
consumed after replacement. The codegen fixture compares every case-pair switch,
parent merge, multiple independent groups, retained original values, malformed
input and budget boundaries with Python Protobuf. Naming rules and the public
selection API are documented in the [generator guide](../../tools/protoc-gen-roc/README.md#oneofs).
Recursive schema generation and encoder limits are described below.

## Recursive codecs and traversal limits

Cyclic message components share a deterministic module with nominal types,
boxed singular/oneof edges, and ordinary lists/maps for repeated fields. Acyclic
ancestors import the component without introducing cyclic module imports. The
[generator contract](../../tools/protoc-gen-roc/README.md#recursive-messages-and-encoder-limits)
defines naming, collision rejection, and the pinned compiler's recursive equality
limitation. Generated types containing recursive descendants do not expose
`is_eq`; independent Protobuf values remain the interoperability oracle.

Reader budgets remain cumulative through recursion. Generated encoders charge
the root and every nested message visit on the same writer, including empty
messages and repeated visits to shared subtrees. The default maximum depth is
64 and the default visit budget is 65,536; explicit limits are available through
the writer composition API. Packed scalars do not count as nested messages.
Tests exercise self/mutual recursion, cyclic map entries and oneofs, merge,
replacement, retained values, nearest depth/work boundaries, and an exponential
shared-tree workload that terminates with a typed limit error.


## Standalone distribution acceptance

`test-protobuf-package` builds the content-addressed pure Roc bundle and a
reproducible source archive containing the matching generator, setup script,
wire sources, license, and compatibility metadata. It extracts outside the
repository, installs the pinned build tools, generates recursive messages, and
runs codec assertions using a wire bundle fetched over loopback HTTP with fresh
caches. No roxum platform import or host archive is used by this consumer.

`compatibility.json` records the independent shared version, exact Roc revision,
schema subset, and package size limit. Release metadata records both artifact
hashes and URLs. Invalid version/compiler/subset metadata is rejected. The
[distribution guide](../../libraries/roc-protobuf/DISTRIBUTION.md) explains
installation, supported scope, unknown-field loss, and regeneration on upgrade.

Together with `test-protobuf-codegen` and `test-protobuf` on macOS/Linux, the
standalone consumer closes milestone 2 for this subset. It does not establish
support for excluded schemas, all compiler versions, or gRPC services. Typed
Unary dispatch, framing, status, metadata, deadlines, and client acceptance
are covered by the separate [milestone 3 acceptance](../../tests/grpc-unary/README.md).
