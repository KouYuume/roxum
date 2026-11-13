# Protobuf scalar generator pilot

This build-time `protoc` plugin emits pure Roc message codecs using
[ProtobufWire and ProtobufScalar](../../libraries/roc-protobuf/README.md). Generated
code imports no
roxum module or hosted effect. This is an internal feasibility slice of
[gRPC milestone 2](../../docs/plans/protobuf-codegen.md), not a published generator
or a complete Protobuf implementation. Use the generator and wire library from
the same repository revision and the [pinned Roc compiler](../../docs/toolchain.md).

## Supported input

- Proto3 top-level messages, including empty messages.
- All 15 proto3 scalar types as singular fields, with implicit presence or explicit `optional` presence (see below).
- Message names matching `[A-Z][A-Za-z0-9]*` and field names matching
  `[a-z][a-z0-9]*(?:_[a-z0-9]+)*`. Roc keywords, conflicting built-in names,
  `Builtin`, `Main`, `ProtobufWire`, `ProtobufScalar`, and case-insensitive module
  collisions are rejected.
- Reserved schema names/ranges and source metadata do not change codec behavior.
  `protoc` validates schema declarations before invoking the plugin.
- Files may contain services; the plugin ignores service declarations and their
  options. It generates no RPC bindings.

Imports, nested declarations, repeated fields, maps, enums,
real `oneof`, message-valued fields, proto2, editions, and extensions are rejected.
All file/message/field/oneof options are rejected in this pilot, including options
for other languages. Names are not automatically transformed. Proto package
names do not become Roc namespaces; message module names must be unique across
all files in one invocation. Validation completes before any output is returned;
errors identify the file/symbol where possible.

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
each must contain exactly one scalar marked `proto3_optional`, with a valid
oneof index and no oneof options. Their names are descriptor metadata and are
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
strings charge zero bytes; duplicates still consume tag budget. This subset
creates no repeated/map entries, so `entries` is not consumed. The record has a schema-fixed size.
`encode` takes a maximum output length and returns
`Try(List(U8), ProtobufWire.Error)`; it omits absent fields and implicit default-valued fields, and writes in
field-number order. String encoding checks capacity for the full length-prefixed
value before converting it to a byte list. Neither API parses a gRPC envelope or
assigns gRPC statuses.

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
  tests/protobuf-codegen/scalar.proto
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
payloads. It does not generate codecs or enable recursive schemas. Generated
imports/namespaces, shared recursive budgets, merge behavior, and bounded
composition remain prerequisites to expanding composite support. This pilot
does not complete milestone 2 or make Unary gRPC available.
