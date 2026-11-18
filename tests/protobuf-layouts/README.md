# Protobuf type layout feasibility

This handwritten fixture checks candidate Roc type layouts before the Protobuf
generator accepts composite schemas. It is not generated code, a Protobuf
codec, or an interoperability test. Generated message, enum, map, oneof, and
bounded recursive codecs are tested separately by `test-protobuf-codegen`.

The pure `layouts` package imports no platform or hosted effects. Its types
exercise these shapes:

| Shape | Candidate representation | Runtime observation |
|---|---|---|
| Imported message payload | A nominal `Leaf` record in a separate module, with `Str` and `List(U8)` fields | Imported construction and matching; shared heap-backed payloads |
| Self-recursive singular message | `[Absent, Present(Box(Node))]` | Empty edge and chains with an explicit terminal record |
| Mutually recursive messages | Co-located `Left` / `Right` records referring to each other through presence tags and `Box` | Alternating types, ending at either side |
| Repeated recursive messages | `List(Tree)` | Empty children and a comb-shaped tree sharing its terminal value |

`Observe` traverses the exported nominal types from another module. The HTTP
fixture accepts exactly two bytes (depth and seed), limits depth to 64 before
construction, and supplies request-dependent strings and byte lists. Depth
counts edges; depth zero contains one record. The comb tree has `2 * depth + 1`
logical nodes, avoiding exponential traversal. These are test limits, not a
new public decoder contract.

For each shape, the application observes the original value, replaces its child
or children with absence/empty, and observes both the replacement and the still
live original. Python checks node counts, numeric/payload checksums, and byte
counts using closed-form arithmetic, not the Roc traversal algorithm. Cases
cover depth 0, 1, 2, 63, 64, and rejected 65; byte extremes and decimal-width
transitions; input length boundaries; and repeated requests carrying different
deep values. In tracking mode, every completed request must emit an allocator
contract success marker. Successful shutdown is also required.

```sh
python3 tools/check.py --only test-protobuf-layouts
bash tools/linux/test.sh python3 tools/check.py --only test-protobuf-layouts
```

Both commands build and run all three backends and both allocator modes. The
same group is available as `zig build test-protobuf-layouts` and is included in
the full release verification suite.

## Design consequence and remaining gates

The pinned compiler can represent these bounded recursive records using normal
Roc values: a new host handle or hosted effect is not required by the fixture.
Generated codecs co-locate cyclic message components in a module and use `Box`
for singular edges within a component. Naming, imports, descriptor validation,
and wire behavior are covered separately by `test-protobuf-codegen`.

This fixture establishes only the exercised layouts and depth. The generated
codec fixtures additionally check shared decoding budgets, duplicate-message
merges, map and oneof semantics, bounded encoding, and independent wire
interoperability. They distinguish `Absent` from a present empty child.
Recursive equality is not generated because the pinned compiler cannot derive
it for these records; see the [generator contract](../../tools/protoc-gen-roc/CODECS.md#recursive-messages-and-encoder-limits).

## Open enum candidate

`Status` wraps an `I32` in a distinct nominal type. Named constants can alias the
same numeric value; `from_number` and `to_number` retain unknown values without
turning them into the zero default. The fixture imports the type across a module
boundary and places it in a record, explicit presence, and a list. It observes a
retained original after replacing the optional/list fields. Python assertions
cover both signed extremes and their neighbors, declared zero/one values and
neighboring unknown values. Present zero differs from absence; alias constants
compare equal. Input length is checked before constructing the value.

This fixture tests the runtime representation only. Generated enum wire codecs,
descriptor validation, and naming/import rules are tested separately by
`test-protobuf-codegen`.

## Map candidate

`Maps` stores each legal proto3 key representation in a typed `Dict`: `I32`,
`I64`, `U32`, `U64`, `Bool`, and `Str`. Integer encodings with the same signedness
and width share the Roc key type; generated entry codecs preserve each field's
wire encoding. Values exercise imported nominal messages with heap-backed text
and bytes, open enums (including unknown numbers), byte lists, and strings.

The `/maps` fixture accepts zero to 64 little-endian `U64` words and derives each
key representation from their bits. These words are test input, not Protobuf
bytes. It builds the dictionaries, replaces the last key's values (or inserts
zero/false/empty-string keys for empty input), and observes the original again.
A separate Roc module traverses every dictionary and looks up each key. Python
compares the entries with its own dictionaries without depending on iteration
order. Tests include defaults, signed/unsigned width transitions, duplicate keys,
empty maps, the 63/64/65 entry bound, malformed word lengths, and repeated requests
with 64 heap-backed keys. Tracking mode checks release for every request.

This verifies the `Dict` layouts and value retention used by generated maps.
Generated wire semantics, descriptor validation, shared decode budgets, and
bounded output are tested separately by `test-protobuf-codegen`. Iteration order
is not a Protobuf ordering contract; deterministic serialization is not
established by this fixture.
