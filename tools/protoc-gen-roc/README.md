# Protobuf scalar generator pilot

This build-time `protoc` plugin emits pure Roc message codecs using
[ProtobufWire and ProtobufScalar](../../libraries/roc-protobuf/README.md). Generated
code imports no
roxum module or hosted effect. This is an internal feasibility slice of
[gRPC milestone 2](../../docs/plans/protobuf-codegen.md), not a published generator
or a complete Protobuf implementation. Use the generator and wire library from
the same repository revision and the [pinned Roc compiler](../../docs/toolchain.md).

## Supported input

- Proto3 top-level and lexically nested messages, including empty messages.
  Nesting declares independent codecs; singular message fields may reference them.
- Singular message fields in acyclic type graphs, with explicit presence and wire merge.
- Repeated `string`, `bytes`, and acyclic messages, represented by `List(Str)`,
  `List(List(U8))`, and `List(Child)`.
- Repeated `uint32`, `uint64`, `fixed32`, and `fixed64`, with packed and unpacked input.
- All 15 proto3 scalar types as singular fields, with implicit presence or explicit `optional` presence (see below).
- Message names matching `[A-Z][A-Za-z0-9]*` and field names matching
  `[a-z][a-z0-9]*(?:_[a-z0-9]+)*`. Roc keywords, conflicting built-in names,
  `Builtin`, `Main`, `ProtobufWire`, `ProtobufScalar`, and case-insensitive module
  collisions are rejected.
- Reserved schema names/ranges and source metadata do not change codec behavior.
  `protoc` validates schema declarations before invoking the plugin.
- Files may contain services; the plugin ignores service declarations and their
  options. It generates no RPC bindings.

Repeated signed integers, booleans, floats, maps, enums, real `oneof`, recursive message fields, proto2,
editions, extensions, and weak imports are rejected.
The `packed` field option is accepted only on the supported repeated unsigned
integer fields. All other file/message/field/oneof options are rejected in this
pilot, including options for other languages. Validation completes before any output is returned;
errors identify the file and fully qualified symbol where possible.

## Schema identities and imports

The generator keeps each message's fully qualified Protobuf identity, including
its package and enclosing messages. Top-level names retain their spelling;
nested names concatenate enclosing message names. For example:

| Protobuf identity | Generated nominal type / module |
|---|---|
| `.probe.Packet` | `Packet` |
| `.probe.Envelope` | `Envelope` |
| `.probe.Envelope.Payload` | `EnvelopePayload` |
| `.catalog.Entry.Detail` | `EntryDetail` |

Every local message name must match the supported type-name pattern. Generated
module names must be unique, case-insensitively, across the whole invocation and
must not conflict with the reserved modules listed above. For example, a
top-level `EnvelopePayload` collides with `Envelope.Payload`; `a.Packet` and
`b.Packet` also collide. The generator rejects these schemas rather than adding
suffixes. Package names are part of schema identity, not Roc namespaces. The
original fully qualified identity appears in each generated module's comment.

Ordinary and public imports are accepted only when **every imported file is
explicitly listed as a generation target in the same invocation**, including
transitive imports. The resulting directory is one standalone Roc package;
there is no external generated-package mapping or automatic dependency output.
Missing targets/descriptors, duplicate or cyclic imports, invalid public import
indices, and weak imports fail before output. All selected messages, including
nested and imported declarations, undergo the same supported-subset validation. Files
containing only services or import declarations may participate, but the whole
invocation must contain at least one message.

Message fields resolve canonical fully qualified descriptor names. Targets must
be in the same file, a direct import, or an import exposed transitively through
public imports. Unknown or invisible targets and cycles in the message-field
graph fail before output. Recursive schemas and well-known types remain unsupported.

## Singular message fields

A message field uses `[Absent, Present(Child)]`; defaults are `Absent`. For an absent
field, an empty wire occurrence sets `Present(Child.defaults)`, and encoding a present empty
child writes its tag and zero length. Wrong-wire occurrences do not change
presence. Duplicate occurrences merge into the existing child, retaining absent
fields and replacing scalar wire occurrences, including explicit defaults.
This also applies through multiple acyclic message levels.

Generated decoders enter/leave scopes on the same reader; input, field, depth,
tag and materialization limits remain shared. Encoders use `write_message` and
buffer children within remaining output capacity. Acyclic schema depth bounds
call nesting; total temporary memory can scale with schema depth and output
limit. There is no independent encoder depth/work limit. Do not interpret the
output bound as a total allocation bound. Message fields with or without explicit
`optional` use the same presence and merge behavior. Synthetic oneofs remain descriptor metadata and do not introduce
a user-facing union beyond `Absent / Present`. Repeated signed integers, booleans, floats, maps and real
oneofs remain unsupported.

## Repeated strings and bytes

Repeated strings and bytes default to an empty list. Decoding appends every
matching occurrence in wire order, including empty and duplicate values. Merged
message occurrences append to the existing lists. Wrong-wire and unknown fields
are skipped and do not consume collection entries.

Each recognized element reserves one shared `entries` unit before reading or
appending. Existing string/byte readers enforce field and cumulative materialized
byte limits; strings charge both their byte read and UTF-8 conversion. List
storage is bounded logically by entries, not included as exact allocator bytes.
Encoding emits each element, including empty values, against the accumulated
writer capacity. See below for unsigned packed fields.

## Repeated messages

Acyclic message lists use `List(Child)`. Each wire occurrence decodes from
`Child.defaults` and appends a separate element; adjacent occurrences never merge
with each other. Empty messages remain elements. Merging an enclosing singular
message appends to its existing list. Encoding writes each element with its own
tag and length prefix using the bounded child writer.

Each message element reserves one shared entry before entering its reader scope.
Nested lists consume the same entry budget, and field, depth, tag, and
materialization budgets remain shared. Recursive message graphs are still
rejected, including cycles through repeated fields.

## Repeated unsigned integers

Repeated `uint32`, `uint64`, `fixed32`, and `fixed64` use `List(U32)` or `List(U64)`
and default to empty lists. Decoders accept both packed length-delimited segments
and individual unpacked values, regardless of the schema's `packed` option.
Multiple segments and mixed forms append in wire order, including zero values.
Merging parent occurrences appends to existing lists. Packed `uint32` conversion
keeps the low 32 bits, just like its unpacked scalar reader.

Each element consumes one shared entry before allocation. Packed segments do not
add message depth or materialized-byte charges; their temporary raw-value lists
and destination lists are bounded logically by the entry budget. Tags count wire
occurrences, including empty segments. Packed lengths obey the same field limit,
and an incomplete element cannot read beyond its segment or containing message.

Encoding defaults to one packed segment per nonempty list, also when
`packed=true` is explicit. `packed=false` emits a tag for each element. Empty lists
emit nothing. Packed encoding uses a temporary child writer bounded by remaining
output capacity; the final tag, length prefix, and payload must all fit the
accumulated writer. This is a logical output bound, not a total allocation limit.
Signed integer, boolean, and floating-point repeated fields remain unsupported.

## Scalar representation

| Protobuf type | Roc type |
|---|---|
| `uint32`, `fixed32` | `U32` |
| `uint64`, `fixed64` | `U64` |
| `int32`, `sint32`, `sfixed32` | `I32` |
| `int64`, `sint64`, `sfixed64` | `I64` |
| `bool` | `Bool` |
| `string` | `Str` |
| `bytes` | `List(U8)` |
| `float` | `F32` |
| `double` | `F64` |

Integer conversion follows the declared wire encoding: negative `int32`/`int64`
use sign-extended varints; `sint32`/`sint64` use ZigZag. After bounded 64-bit
varint parsing, 32-bit decoders keep the low 32 bits. Booleans decode any nonzero
varint as true and encode only 0 or 1. See the
[encoding specification](https://protobuf.dev/programming-guides/encoding/).

Known strings require valid UTF-8 and return `InvalidUtf8` on failure. Bytes and
unknown length-delimited fields are not interpreted as text. Floating-point
codecs preserve finite values, subnormals, signed zero, and infinities. Only
positive zero is omitted as the implicit default. NaNs remain NaNs, but Roc's
`to_bits` canonicalizes their sign and payload to `0x7fc00000` / `0x7ff8000000000000`;
this codec does not preserve NaN payloads. This uses the pinned compiler's
[native float conversion APIs](https://github.com/roc-lang/roc/blob/9e85de7aba79eaeb8ca589ab6a1ea581274c8930/src/build/roc/Builtin.roc),
verified through generated codecs on all three backends.

## Explicit scalar presence

A proto3 `optional` scalar uses `[Absent, Present(T)]`, where `T` is the scalar
type above. `defaults` initializes it to `Absent`. For example, with
`optional uint32 count = 1`, set `count: Present(0)` to encode a present zero,
and `count: Absent` to omit the field. Pattern matching exposes presence and the
value together; there is no separate boolean that can disagree with the value.
This follows the [Protobuf presence contract](https://protobuf.dev/programming-guides/field_presence/).

Every successfully decoded occurrence sets `Present(value)`, including zero,
false, empty bytes, and empty strings. The last occurrence wins. Encoding emits
every `Present` value, including positive floating-point zero. Wrong-wire-type
occurrences are skipped without setting or clearing presence. Fields without
`optional` retain implicit default omission in the same message.

The plugin advertises `FEATURE_PROTO3_OPTIONAL` and validates synthetic oneofs:
each must contain exactly one supported field marked `proto3_optional`, with a
valid oneof index and no oneof options. Their names are descriptor metadata and are
not exposed in the Roc API. Real oneofs, including single-member real oneofs,
remain unsupported. Invalid metadata fails before any generated files are
returned.

## Generated API and limits

Each message becomes a nominal record with `defaults`, `decode`, and `encode`:

```roc
Packet.decode(bytes, ProtobufWire.default_limits)
Packet.encode(Packet.{ count: 1, code: 2, stamp: 3, payload: [4] }, 4096)
```

`decode` takes one complete serialized message and explicit `ProtobufWire.Limits`.
It returns `Try(Message, ProtobufWire.Error)`. Duplicate singular fields use the
last value, including a default value that replaces an earlier non-default.
Unknown fields and known fields with different wire types are validated and
skipped. **Unknown data is discarded**, so this is not a lossless relay.

The reader carries input, field-length, tag, group-depth, and cumulative byte
materialization budgets through the whole message. Replacing a `bytes` field
does not refund the copied-byte budget. A string charges twice its UTF-8 byte
length: once for the wire byte slice and once before conversion to `Str`. This
conservative accounting applies even if the compiler can reuse storage. Empty
strings charge zero bytes; duplicates still consume tag budget. Each repeated
element, including an empty message or payload, also consumes one shared
`entries` unit. Singular fields do not consume collection entries.
`encode` takes a maximum output length and returns
`Try(List(U8), ProtobufWire.Error)`; it omits absent fields and implicit default-valued fields, and writes in
field-number order. String encoding checks capacity for the full length-prefixed
value before converting it to a byte list. Neither API parses a gRPC envelope or
assigns gRPC statuses.

## Composing generated codecs

The generated types also expose two lower-level pure functions for codec
composition. The existing `decode` and `encode` APIs delegate to them; their
standalone behavior is unchanged.

```roc
Packet.decode_into(reader, initial)
Packet.encode_into(value, writer)
```

`decode_into` returns `Try((Message, ProtobufWire.Reader), ProtobufWire.Error)`.
It consumes exactly the reader's current scope, starting from `initial`, and
returns the reader with its accumulated counters. Missing fields retain their
initial value. Each known scalar occurrence replaces that field, including
explicit zero/empty values for implicit scalars and `Present(default)` for
optional scalars. Unknown fields and wrong-wire-type occurrences are validated
and skipped without clearing the initial value. This is a **wire merge**; it is
not an object merge that ignores default-valued implicit fields.

The caller enters and leaves child scopes explicitly:

```roc
inside = ProtobufWire.enter_message(reader)?
(merged, after_child) = Packet.decode_into(inside, previous)?
after = ProtobufWire.leave_message(after_child)?
```

Pass the reader returned by every operation onward. `decode_into` creates no
reader and does not enter or leave scopes; a truncated child cannot consume its
parent's following fields. Tags, materialization, and depth remain shared with
the parent and subsequent children, including repeated occurrences that replace
earlier values. Initial values are already constructed and are not charged
again; the budget accounts for processing the supplied reader, not arbitrary
storage supplied by the caller. Old values remain usable after a successful
merge. As with the wire API, retaining and reusing an old reader deliberately
replays its input and budget; these are pure values rather than linear handles.

`encode_into` returns `Try(ProtobufWire.Writer, ProtobufWire.Error)`. It appends
fields to the supplied writer and preserves its existing bytes and total output
limit. It writes neither an enclosing tag nor a length prefix. Empty messages
leave the writer unchanged. Errors return no partially advanced reader/writer;
retained inputs remain available to the caller.

Generated acyclic message fields use these helpers for shared reader state and
wire merge. Recursive schemas remain unsupported. The wire
library provides `write_message(writer, value, Message.encode_into)` for bounded,
buffered child output; the caller writes the field tag first. Recursive encoding
still needs a depth/work policy.

## Toolchain and generation

Requires Python 3.9+ and the pinned Roc compiler on `PATH` (or `ROC_BIN`). From the
repository root:

```sh
python3 tools/protoc-gen-roc/setup.py
mkdir -p zig-out/scalar-example
zig-out/protobuf-codegen/bin/protoc \
  -I tests/protobuf-codegen \
  --plugin=protoc-gen-roc=tools/protoc-gen-roc/protoc-gen-roc \
  --roc_out=wire=../../libraries/roc-protobuf/package/main.roc:zig-out/scalar-example \
  tests/protobuf-codegen/scalar.proto tests/protobuf-codegen/catalog.proto
```

The required `wire` parameter is the package path as seen from generated
`main.roc`. Only letters, digits, `_`, `.`, `/`, `:`, and `-` are accepted in that
parameter; use a local path for this pilot. The output is one module per message
and `main.roc`. Keep each invocation's output in its own directory. The plugin
uses stdout only for the binary `CodeGeneratorResponse`.

`setup.py` installs under ignored `zig-out/protobuf-codegen`. It checks official
archive hashes before extracting only `bin/protoc`. Python dependencies are
installed in a private venv with required hashes. No dependency is added to
deployed applications. Version pins:

| Tool | Pin | License / lock |
|---|---|---|
| Official `protoc` | [33.5](https://github.com/protocolbuffers/protobuf/releases/tag/v33.5) | [BSD-3-Clause](https://github.com/protocolbuffers/protobuf/blob/v33.5/LICENSE); macOS universal, Linux aarch64/x86_64 archive hashes in [setup.py](setup.py) |
| Official Python Protobuf and independent test implementation | [6.33.5](https://pypi.org/project/protobuf/6.33.5/) | BSD-3-Clause; universal pure Python wheel in [requirements.txt](requirements.txt) |

The upstream compiler also uses third-party code, including
[Abseil (Apache-2.0)](https://github.com/abseil/abseil-cpp/blob/master/LICENSE)
and [utf8_range (MIT)](https://github.com/protocolbuffers/protobuf/blob/v33.5/third_party/utf8_range/LICENSE).
The downloaded tools are not included in roxum release bundles. These matching
compiler/runtime releases avoid generating Python test bindings with a newer
compiler than their runtime.

## Verification

```sh
python3 tools/check.py --only test-protobuf-codegen
bash tools/linux/test.sh python3 tools/check.py --only test-protobuf-codegen
```

The group installs pinned tools, runs descriptor rejection tests, regenerates
and formats the fixture with the pinned Roc compiler, checks for drift, and
compiles/runs the generated code across all three backends and both allocators.
To intentionally update the committed fixture after changing the generator:

```sh
python3 tests/protobuf-codegen/regenerate.py --write
```

The application is only a test transport. Tests use independently generated
Python bindings to check values in both directions, directly inspect decoded
Roc record fields, and construct a Roc record independently of decoding.
They cover defaults, duplicates, wrong wire types, unknown fields/groups,
truncation, overflow, deterministic generation, and resource boundaries. Scalar
cases include signed limits, 32-bit truncation, noncanonical booleans, invalid
UTF-8 classes, and IEEE zero/subnormal/normal/infinity/NaN patterns. Floating-point
assertions compare non-NaN bits and NaN classes, not ordinary float equality.

The pinned pure Python decoder dispatches on raw tag bytes: an overlong tag
such as `88 00` is treated as unknown, although it numerically denotes field 1
with varint encoding. That case has an explicit Roc contract assertion rather
than using Python's default-valued field as an oracle. Non-minimal value varints
are still compared with Python. See the upstream
[decoder](https://github.com/protocolbuffers/protobuf/blob/v33.5/python/google/protobuf/internal/decoder.py).

Optional scalar layouts are verified across all scalar types and backends. Tests
compare presence with Python `HasField`, directly inspect Roc tags and values,
construct present-default values in Roc, clear fields, and exercise duplicates,
wrong wire types, malformed values, and cumulative/output bounds.
A separate [handwritten layout fixture](../../tests/protobuf-layouts/README.md)
checks bounded self/mutual recursion, recursive lists, and cross-module nominal
payloads. It does not generate codecs or enable recursive schemas.

Generated nested and imported scalar codecs are checked against Python bindings,
including direct Roc value views and independent construction. Descriptor and
real `protoc` tests cover import closure, flattening/package/case collisions,
atomic rejection, and deterministic output. Acyclic message references, shared
reader budgets, duplicate-child merges, and bounded composition are covered by
generated envelope codecs. Recursive schemas remain unsupported. This pilot does not complete
milestone 2 or make Unary gRPC available.

The composition fixture uses handwritten outer scope handling with generated
scalar codecs and shared envelope schemas. It checks merges across child
occurrences against the official parser, including implicit wire defaults and
all 15 optional scalar types, retained originals, parent tails, malformed child
boundaries, and shared input/field/depth/tag/materialization limits. A framed
writer test checks prefix preservation and total capacity across generated
fields, an empty codec, and a suffix. The framing is test transport, not itself a
nested-message encoder. Generated envelope codecs are additionally compared
with the same Python oracle for presence, merge, shared limits, nested levels,
and length-delimited output.

Unsigned-list fixtures compare all four types and explicit packing options with
Python in both directions, inspect decoded Roc lists directly, and test mixed
segments, zero values, width limits, uint32 truncation, parent merges, retained
initial values, malformed boundaries, shared entry/tag limits, and output limits.
