# Recursive message layout feasibility

This handwritten fixture checks candidate Roc type layouts before the Protobuf
generator accepts composite schemas. It is not generated code, a Protobuf
codec, or an interoperability test. The generator still rejects message-valued
fields, repeated fields, and recursive schemas.

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
Co-locating mutually recursive nominal definitions is a viable candidate for a
generated type component; this fixture does not determine whether cyclic module
imports work or require every schema to use one module. Fully qualified schema
identities, collision-free names, and generated imports still need a separate
design and fixture before enabling those features.

This is evidence for the exercised layouts and depth, not proof of arbitrary
recursion safety. Generated nested-message parsing still needs shared depth,
field/tag/entry/materialization budgets, duplicate-message merge behavior,
bounded encoding, and independent wire interoperability. The fixture also does
not establish map, enum, oneof, or recursive equality behavior. In particular,
`Absent` and a present empty child must remain distinct when codecs are added.
