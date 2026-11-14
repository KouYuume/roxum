# Protobuf wire and scalar codecs

`package/main.roc` exports `ProtobufWire` and `ProtobufScalar`, pure Roc modules
with no platform or hosted imports. They support
[gRPC milestone 2](../../docs/plans/protobuf-codegen.md) and are not yet published
packages. The [generator pilot](../../tools/protoc-gen-roc/README.md) composes them
into codecs for singular scalar fields with implicit or explicit `optional` presence.

`ProtobufWire` reads/writes unsigned varints, tags, fixed-width words, and
length-delimited bytes. It skips unknown fields, including matched groups, and
can enter/leave length-delimited messages while retaining the same budgets.
The wire reader accepts reserved field numbers because their schema restrictions
do not make incoming unknown fields malformed.

`ProtobufScalar` adds typed signed/unsigned integer conversion, ZigZag, booleans,
UTF-8 strings, and native `F32`/`F64` values. Its `read_<type>` and `write_<type>`
functions use Protobuf type names (for example `read_sint32`, `write_double`),
thread the same reader/writer, and do not read or write field tags. The four
wire-native types continue to use `ProtobufWire` directly. See the generator's
[scalar representation contract](../../tools/protoc-gen-roc/README.md#scalar-representation)
for truncation, UTF-8, signed-zero, and NaN semantics. Message composition,
presence, enums, repeated fields, maps, and merge rules remain schema-layer work.

## Reader contract

Create a reader with `ProtobufWire.new_reader(input, limits)`. Thread the reader
returned by **every** successful operation into the next operation. These are
pure values, not linear handles: retaining an old reader and using it again
intentionally replays input and its budget. Schema decoders must not restart a
reader for nested messages or reset budgets after overwriting a value.

`remaining` reports bytes left in the current message. `read_tag` consumes one
tag and returns `{ number, kind }` with the next reader. Read the appropriate
value from that reader, or pass it and the tag to `skip`. Reading a scalar never
implicitly reads a tag. `skip` rejects an unmatched end-group and validates
unknown lengths/varints instead of ignoring malformed bytes.

`enter_message` reads a length prefix and bounds the same reader to that payload;
`leave_message` requires exact consumption and restores the parent's end offset.
The root has depth zero. Entered messages and skipped groups share the depth
limit. An empty message still consumes one depth level. The implementation uses
loops and an explicit group stack rather than recursive group parsing.

| Limit | Default | Accounting |
|---|---:|---|
| `input_bytes` | 4 MiB | Entire input, checked when creating the reader |
| `field_bytes` | 4 MiB | Every length-delimited payload, including skipped fields and entered messages |
| `depth` | 64 | Simultaneously entered messages and open skipped groups, excluding the root |
| `tags` | 65,536 | All consumed tags, including unknown fields and end-group delimiters |
| `entries` | 65,536 | Caller reservations before adding repeated/map entries, including overwritten duplicates |
| `materialized_bytes` | 8 MiB | Cumulative byte payloads returned by `read_bytes`, plus explicit caller reservations |

All limits allow equality and zero. `reserve(reader, entries, materialized_bytes)`
charges additional logical storage before allocation. A future schema decoder
must charge collection entries and any storage not already charged by
`read_bytes`; the raw primitives cannot infer those allocations. Skipping unknown
bytes and entering messages do not copy or charge their payload as materialized
storage. Limits are not measurements of allocator overhead, and creating a
reader cannot limit memory already used to receive its input. Bound reception
separately. Counters are never replenished on leaving a message. `read_string` charges its
UTF-8 length for the byte slice and again before the string conversion, including
values later overwritten. This conservative two-copy budget is not refunded
when storage happens to be reused.

Errors are typed tags in `ProtobufWire.Error`, including malformed/truncated
input, mismatched groups, and each exhausted budget. The shared error type also
includes `InvalidUtf8`, emitted by `ProtobufScalar.read_string`. Valid non-minimal varints
are accepted; values beyond 64 bits are rejected before shifting/accumulating.
Each failed operation returns no partial reader or value. When several limits
or malformed conditions apply, the first check encountered determines the error;
callers should not depend on a universal precedence between them.

## Writer contract

`new_writer(max_bytes)` creates an empty bounded writer. Thread the writer
returned by `write_tag`, `write_varint`, `write_fixed32`, `write_fixed64`, or
`write_bytes` into the next operation; `output` returns the accumulated bytes.
`remaining_output` reports unused output capacity. Scalar string encoding uses
it to check the length prefix and payload before creating a UTF-8 byte list.
Lengths and available space are checked before growing output. Varints use their
minimal encoding, fixed words use little endian, and `write_bytes` includes its
length prefix. Groups and tag/value ordering remain the schema encoder's
responsibility. Temporary scalar encodings use at most ten bytes; the configured
limit bounds accumulated output, not every retained copy a caller could make.

## Verification

From the repository root with the pinned toolchain:

```sh
bash tests/protobuf/unit.sh
python3 tools/check.py --only test-protobuf
bash tools/fuzz-roc-protobuf.sh
bash tools/linux/test.sh python3 tools/check.py --only test-protobuf
```

The unit checks cover each 7-bit varint transition, tenth-byte overflow,
truncation, wire types, fixed-width boundaries, nested scopes, group matching,
and lower/exact/upper limit boundaries. Scalar unit checks cover signed/ZigZag
limits, IEEE conversion, UTF-8 rejection, and string materialization/output
bounds. `zig build test` includes both modules' checks.

The fixture executes the library with all three Roc backends and both allocators.
Its Python reference decoder compares normalized output or typed rejection for
fixed vectors, boundary cases, generated streams, truncations, and deterministic
random bytes. This independent wire implementation is not the milestone 2 gate
for generated-schema interoperability with an established Protobuf library.

The pinned Roc fuzz runner checks arbitrary input, parser progress, scalar
read/skip agreement, and varint round trips. A second path generates nested
messages with leaves before and after each child. It threads charged readers
through `reserve`, `read_bytes`, `enter_message`, and `leave_message`, checking
scope boundaries and comparing outcomes with an independent cumulative budget
model. Each input runs with both generous and input-derived small limits.
A scalar path parses arbitrary bytes as each newly supported scalar, checks
progress and canonical re-encoding (including NaNs), and tests exact/undersized
output bounds. Negative controls reject unexpected encode, canonical decode,
and re-encode failures after valid input; only initial input errors are tolerated.
Deterministic scope tests cover the lower, exact, and upper boundaries of the
shared counters and run before fuzz compilation.
Its corpus and seed are retained;
`RUNS` overrides the default 10,000 iterations. The pinned runner ships hosts
only for macOS arm64 and Linux x64. On those environments,
`zig build fuzz-protobuf` and the complete `tools/check.py` suite run this target.
Linux arm64 runs the unit/differential matrix, but cannot run this fuzz binary;
the standalone script reports that limitation rather than passing a skipped run.
Schema-aware decoder fuzzing must be added when that decoder exists.

## Length-delimited writer composition

`ProtobufWire.write_message(writer, value, encode_into)` invokes a pure encoder
with a fresh child writer bounded by the parent's remaining capacity minus one
byte, then appends its actual length prefix and payload to the parent. Write the
field tag before calling it. The encoder must append to the supplied child
writer and return `Try(ProtobufWire.Writer, ProtobufWire.Error)`, as generated
`Message.encode_into` does. Empty payloads
still need a one-byte prefix. A wider prefix can make the final append fail even
if the child fits; no partial writer is returned. Encoder errors propagate.

This helper buffers the child payload. It bounds each child buffer and final
output, not total allocation across arbitrary recursive composition. Recursive
schema support still requires an explicit depth/work policy. Generated acyclic
message-valued fields use this helper. The composition fixture verifies generated
and handwritten outer encoders against Python, including prefix-width
transitions and total output boundaries.

## Packed scalar payloads

`read_packed_varints`, `read_packed_fixed32`, and `read_packed_fixed64` read one
length-prefixed payload after its field tag. They return a list of raw unsigned
values and the advanced reader. Signed, boolean, and floating-point conversions
belong to schema-aware codecs. Empty segments yield empty lists; non-minimal
varints are accepted, while overflowing or truncated values fail.

A packed payload does not add message depth. Its boundary temporarily narrows
the current reader without copying bytes, and completion restores the containing
scope's end. Elements cannot borrow bytes from the next field or segment. Input
and field-length limits still apply. Each element reserves one shared collection
entry before reading; numeric list slots are bounded by entries rather than
charged as payload materialization. Tags and all other counters remain shared
and are never replenished. The caller reads field tags separately. Fixed-width
payloads must contain complete elements. Errors return no partial list or reader.

Generated numeric and boolean repeated fields use these helpers.
`ProtobufScalar.read_packed_int32`, `read_packed_int64`, `read_packed_sint32`,
`read_packed_sint64`, `read_packed_sfixed32`, `read_packed_sfixed64`,
`read_packed_bool`, `read_packed_float`, and `read_packed_double` add typed list
conversion without reserving entries a second time. They return the converted
list and the same advanced reader. The caller consumes the field tag first.
Their temporary raw and typed lists share the logical entry bound; list storage
is not charged as materialized byte payloads. Conversion preserves scalar
semantics, including 32-bit truncation, nonzero booleans, signed zero, and NaN
canonicalization on encoding. Errors propagate without a partial list or reader.
