# protoc-gen-roc

Generate Roc codecs from proto3 schemas with the `wire` package option.
Add `grpc` and `pf` to generate roxum service registrations for Unary,
server-streaming, client-streaming and bidirectional methods.
For a released generator and matching wire library, follow the
[distribution guide](../../libraries/roc-protobuf/DISTRIBUTION.md).

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
parameter. For a bundle URL, pass `--roc_opt=wire=<URL>` and `--roc_out=<directory>` separately. The output contains `main.roc` and
one module per enum, acyclic message, or cyclic message component. Keep each
invocation's output in its own directory. The plugin
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

## Supported input

- Proto3 top-level and lexically nested messages, including empty messages.
  Nesting declares independent codecs; singular message fields may reference them.
- Singular message fields in acyclic and recursive type graphs, with explicit presence and wire merge.
- Repeated `string`, `bytes`, and messages, represented by `List(Str)`,
  `List(List(U8))`, and `List(Child)`.
- All numeric and boolean scalar types as repeated fields, with packed and unpacked input.
- Proto3 maps with all legal key types and scalar, enum, or message values.
- Open proto3 enums, including aliases and unknown numeric values.
- Real oneofs containing scalar, enum, or message fields, with explicit unset state.
- All 15 proto3 scalar types as singular fields, with implicit presence or explicit `optional` presence.
- Message names matching `[A-Z][A-Za-z0-9]*` and field names matching
  `[a-z][a-z0-9]*(?:_[a-z0-9]+)*`. Roc keywords, conflicting built-in names,
  `Builtin`, `Main`, `ProtobufWire`, `ProtobufScalar`, and case-insensitive module
  collisions are rejected.
- Reserved schema names/ranges and source metadata do not change codec behavior.
  `protoc` validates schema declarations before invoking the plugin.
- In codec-only mode, files may contain services; the plugin ignores service declarations and their
  options. It generates no RPC bindings.

Proto2, editions, extensions, and weak imports are rejected.
The `packed` field option is accepted only on the supported repeated numeric, enum,
and boolean fields. The enum option `allow_alias` and validated synthetic `map_entry` message option are also accepted. All other file/message/field/oneof options are rejected, including options for other languages. Validation completes before any output is returned;
errors identify the file and fully qualified symbol where possible.

See the [codec reference](CODECS.md) for generated names, field representations,
presence, merge behavior, recursive types, and decoder/encoder budgets.

## Optional roxum service bindings

Use `wire=<path>,grpc=<integration package path>,pf=<platform path>` to generate
typed service registration modules alongside codecs. Without these options the
output remains platform-free. See [the integration contract](../../integrations/roxum-grpc/README.md)
for all four RPC forms, their limits and deadline guarantees. For a bidirectional
method, supply the `duplex_<lowercase method name>` record with `begin!`,
`receive!` and `next!` callbacks.

## Verification

Run `python3 tools/check.py --only test-protobuf-codegen` for descriptor rejection,
fixture regeneration and codec interoperability across backends and allocators.
After changing the generator, refresh its fixtures with
`python3 tests/protobuf-codegen/regenerate.py --write`. Run
`python3 tools/check.py --only test-protobuf-package` to check the extracted
generator with a URL-fetched wire package.

The pinned pure Python decoder dispatches on raw tag bytes. For an overlong tag
such as `88 00`, the fixture asserts the decoded Roc field directly. It uses
Python as the oracle for non-minimal value varints.
