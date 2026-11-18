# Generated Roc codec reference

For installation and generation commands, see [protoc-gen-roc](README.md).

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
must not conflict with the reserved modules in the [supported input rules](README.md#supported-input). For example, a
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
public imports. Unknown or invisible targets fail before output. Cyclic message components use
the module layout described below. Well-known types remain unsupported.

## Singular message fields

A message field uses `[Absent, Present(Child)]`; defaults are `Absent`. For an absent
field, an empty wire occurrence sets `Present(Child.defaults)`, and encoding a present empty
child writes its tag and zero length. Wrong-wire occurrences do not change
presence. Duplicate occurrences merge into the existing child, retaining absent
fields and replacing scalar wire occurrences, including explicit defaults.
This also applies through bounded recursive message levels.

Generated decoders enter/leave scopes on the same reader; input, field, depth,
tag and materialization limits remain shared. Encoders use `write_message` and
buffer children within remaining output capacity. Writer depth and visited-message
limits bound recursive traversal; total temporary memory can scale with the
active depth and output limit. Do not interpret the
output bound as a total allocation bound. Message fields with or without explicit
`optional` use the same presence and merge behavior. Synthetic oneofs remain descriptor metadata and do not introduce
a user-facing union beyond `Absent / Present`. Real oneofs use the tagged selection described below.

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
writer capacity. See below for numeric and boolean packed fields.

## Repeated messages

Message lists use `List(Child)`. Each wire occurrence decodes from
`Child.defaults` and appends a separate element; adjacent occurrences never merge
with each other. Empty messages remain elements. Merging an enclosing singular
message appends to its existing list. Encoding writes each element with its own
tag and length prefix using the bounded child writer.

Each message element reserves one shared entry before entering its reader scope.
Nested lists consume the same entry budget, and field, depth, tag, and
materialization budgets remain shared, including cycles through repeated fields.

## Repeated numeric and boolean fields

Every numeric and boolean scalar uses `List(T)` with its scalar Roc type below
and defaults to an empty list. Decoders accept both packed length-delimited segments
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
Signed integers use the same width conversion and ZigZag rules as singular
fields. Boolean lists accept any nonzero varint as true. Floating-point lists
retain every element, including positive/negative zero and NaNs; encoding
canonicalizes NaN bits just as the singular codec does.

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
not exposed in the Roc API. Real oneofs generate a tagged selection as described under [Oneofs](#oneofs). Invalid metadata fails before any generated files are
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
leave output unchanged but consume one message visit. Errors return no partially advanced reader/writer;
retained inputs remain available to the caller.

Generated message fields use these helpers for shared reader state and wire
merge. The wire library provides `write_message(writer, value, Message.encode_into)` for bounded,
buffered child output; the caller writes the field tag first. Generated message
codecs enter and leave a writer scope, sharing depth and visited-message limits.

## Open enums

Proto3 enums generate nominal `I32` wrappers in separate modules. Top-level,
nested and imported enum identities follow the same visibility, flattened naming
and collision rules as messages. Enum-only files may be generation targets.
Enum names use the message type-name pattern. Value names must use uppercase
snake case and become lowercase constants without stripping a prefix:
`STATE_READY` becomes `State.state_ready`. Names colliding with Roc keywords or
the enum's generated methods are rejected. The first value must be zero;
duplicate numbers require `allow_alias=true`. Other enum/value options are rejected.

`State.from_number(number)` and `State.to_number(value)` preserve unknown signed
32-bit values. Aliases compare equal because they carry the same number. Fields
use the nominal enum type, `[Absent, Present(State)]`, or `List(State)`. Implicit
zero is omitted, present zero is encoded, and repeated values retain order.
Both packed and unpacked enum input are accepted; packing options govern output.
Wire conversion uses the int32 codec, including sign-extended negative output and
low-32-bit conversion after bounded varint parsing. Unknown enum numbers remain
in known fields; this differs from discarded unknown fields. See the official
[open enum contract](https://protobuf.dev/programming-guides/enum/).

Generated enum modules expose `read_int32`, `write_int32`, and
`read_packed_int32` for codec composition, retaining shared wire-reader budgets.
The enum fixtures compare Python and Roc values and presence, imported/nested
types, aliases, unknown signed extremes, mixed packing, parent merge, malformed
input, and entry/tag/output limits across all backends and allocators.

## Maps

A `map<K, V>` field becomes `Dict(K, V)` with `Dict.empty()` as its default.
The declared integer width and signedness determine the Roc key type; the entry
codec preserves its declared varint, ZigZag, or fixed-width encoding. String and
boolean keys remain `Str` and `Bool`. Enum values retain their nominal wrapper
and unknown numbers. Message values are direct `Child` values, not presence tags.

Following the [proto3 map contract](https://protobuf.dev/programming-guides/proto3/#maps),
each entry starts from defaults. Missing keys use zero, false, or the empty string;
missing values use the scalar/enum default or `Child.defaults`. Duplicate keys
replace the complete preceding value, including when the new entry omits its
value. Duplicate message value occurrences within a single entry merge. Merging
parent messages applies the same last-entry-wins behavior to their maps.

Each recognized entry reserves one shared collection entry before entering its
message scope, even if it replaces an existing key. Entry and message-value
scopes count toward depth. Tags and materialized key/value bytes share the same
reader budgets, including overwritten values; string materialization retains the
wire library's byte-read and UTF-8 conversion charges. Unknown entry members and
wrong-wire members are validated and skipped without changing known members.

Encoding emits one length-delimited entry per dictionary item using the bounded
writer. Scalar defaults may be omitted inside entries; message values, including
empty messages, are emitted. Dictionary traversal order is not a serialization
ordering guarantee. Compare decoded values, not byte identity; this is not a
canonical or deterministic serialization API.

Synthetic entry descriptors must have exactly the singular `key=1` and `value=2`
fields, legal key types, and one repeated field in their enclosing message.
Their names must match the parent field's generated `Entry` name; nested
entry declarations, direct map-valued entries, and unsupported options fail
before any output. Entry helper modules are emitted with ordinary flattened
names and participate in package-wide collision checks. Applications use the
parent's `Dict` field; helper modules are not additional application message
schemas. Recursive components follow the layout below.

Interoperability fixtures exercise all 12 legal key encodings, defaults, unknown
enum values, scalar and message values, duplicate entries and members, parent
merge, unknown/wrong-wire members, malformed inputs, and shared resource/output
boundaries. A separate Roc construction case verifies encoding independently of
decoding. Python comparisons ignore map ordering.

## Oneofs

Each real oneof becomes one record field named after the group. Its type is a
closed tag union: `oneof choice { uint64 count = 1; string text = 2; }` becomes
`choice : [Unset, Count(U64), Text(Str)]`, defaulting to `Unset`. Member names
become PascalCase tags by capitalizing each underscore-separated segment. Group
names follow the same lowercase identifier rules as fields. Group/field name
collisions, duplicate generated case tags, and the reserved `Unset` case fail
before output. Synthetic oneofs for proto3 `optional` remain `[Absent, Present(T)]`
fields; they do not generate a selection field.

The [oneof wire rules](https://protobuf.dev/programming-guides/proto3/#oneof)
apply to recognized occurrences. Scalar and enum cases replace the selection;
zero, false, empty string/bytes, and enum zero still select a case and are encoded.
Message cases hold a direct child value, including an empty child. Repeating the
same message case merges into that child. Switching to another case replaces the
old value; switching back starts from the child's defaults, even when both cases
have the same message type. Unknown or wrong-wire fields do not select or clear a
case. Unknown future cases cannot be distinguished from other unknown fields and
are discarded under the existing unknown-field policy.

`decode_into` applies these rules to its initial value, including when parent
message occurrences merge. Oneof members consume the same reader budgets as
ordinary fields. Discarding a previous selection does not restore its consumed
tags, materialization, or nested collection entries. Encoding writes only the
selected member with the bounded writer. There is no additional hosted effect or
runtime handle.

The generated fixture compiles all scalar, enum, and message payloads across the
backend/allocator matrix. Independent Python comparisons cover all case-pair
transitions, selected defaults, multiple groups beside ordinary/optional fields,
message merge and reset, retained original values after clearing, malformed input,
and cumulative limits. Direct Roc construction separately checks encoding.
Real members must be singular and cannot carry proto3 optional metadata; synthetic
groups must follow real groups. Recursive message graphs use the layout below.

## Recursive messages and encoder limits

Mutually reachable messages form a strongly connected component. Each cyclic
component is emitted in one module named after its lexicographically first
flattened message name plus `Recursive`. For example, self-recursive `Node`
becomes `NodeRecursive.Node`; mutually recursive `Left` and `Right` become
`LeftRecursive.Left` and `LeftRecursive.Right`. Module collisions are rejected
before output. Acyclic messages retain their existing module/type names and
import the component when necessary. Synthetic map entries participate in the
same graph. File imports must still form an acyclic, explicitly selected closure.

Singular message and oneof edges within a cyclic component use `Box(Child)`.
Presence remains `[Absent, Present(Box(Child))]`; a selected oneof case carries
`Box(Child)`. Repeated fields use `List(Child)` and maps use `Dict(Key, Child)`.
Their heap storage supplies indirection; map entry helper codecs box their
singular cyclic value internally. Edges from outside a component remain direct
`Child` values with their existing presence wrapper. Applications use `Box.box`
and `Box.unbox` when constructing or matching boxed fields.

The pinned compiler cannot derive equality for these recursive records. The
generator therefore omits `is_eq` for cyclic messages and all messages that
contain them transitively. Acyclic graphs without recursive descendants retain
their existing equality declaration. This limitation does not affect wire
comparison against independent decoded values.

`encode(value, max_bytes)` retains its signature and uses maximum depth 64 and
65,536 visited messages. For explicit limits, call `encode_into` with
`ProtobufWire.new_writer_with_limits({ output_bytes, depth, messages })`.
The root has depth zero and consumes one visit, including an empty root. Every
nested generated message, including synthetic map entries, consumes another
visit; shared subtrees count on every traversal. Sibling visits never replenish
work. Packed scalar payloads do not create message scopes. Exhaustion returns
`DepthLimit` or `MessageLimit`; output overflow still returns `OutputLimit`.

`decode` continues to use the shared reader's limits; recursive defaults contain
no child values until a recognized wire occurrence supplies them. Fixtures cover
self/mutual recursion, lists/maps/oneofs, duplicate merge and replacement,
retained originals, default depth 63/64/65, sibling work bounds, and an application
constructed shared tree whose exponential traversal is stopped by its visit
budget. These logical limits are not an exact total-allocation or CPU-time quota.
Keep caller-supplied limits finite and appropriate for the execution environment.
