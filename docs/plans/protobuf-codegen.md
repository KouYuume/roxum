# Protobuf codec and generator assessment

The wire library and build-time generator implement the `proto3-v1` subset.
For current schema support, generated types and limits, see the
[generator guide](../../tools/protoc-gen-roc/README.md) and
[codec reference](../../tools/protoc-gen-roc/CODECS.md).

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

## Design decision

Use the official descriptor types and plugin protocol at build time.
`protoc` parses schema files; the Python plugin reads a `CodeGeneratorRequest`
and emits Roc modules in a `CodeGeneratorResponse`. The generated message
codecs and their pure Roc wire library run without Python or hosted effects.
Service bindings opt into roxum separately. The [distribution contract](../../libraries/roc-protobuf/DISTRIBUTION.md)
pairs the library and generator versions and pins the compiler.

## Acceptance evidence

| Check | What it verifies |
|---|---|
| [Wire tests](../../libraries/roc-protobuf/README.md#verification) | Primitive reads/writes, skipping unknown fields, parser progress and cumulative budgets. The fuzz runner supports macOS arm64 and Linux x86_64; Linux arm64 runs the module and differential tests. |
| [Layout fixture](../../tests/protobuf-layouts/README.md) | Construction, traversal, replacement and cleanup of recursive Roc values across backends and allocators. |
| [Generator tests](../../tools/protoc-gen-roc/README.md#verification) | Descriptor rejection, deterministic generation and interoperability with independently generated Python messages, including presence, merge, malformed input and resource limits. |
| `test-protobuf-package` | Extract the generator outside the checkout, fetch the wire bundle by URL and exercise a recursive codec with fresh caches. |

For acceptance of generated service registration, transport and gRPC status
handling, see the [gRPC milestones](grpc.md).
