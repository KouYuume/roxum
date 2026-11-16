# Using the Protobuf distribution

The source archive contains the pure Roc wire package and the matching build-time
`protoc-gen-roc` generator. Neither needs roxum. Python and `protoc` are build-time
requirements, not application runtime dependencies. Install Python 3.9 or newer
with `venv` and the Roc compiler identified by `compatibility.json`.

Extract the source archive into a new directory, then run from that directory:

```sh
python3 tools/protoc-gen-roc/setup.py
mkdir generated
zig-out/protobuf-codegen/bin/protoc \
  -I /path/to/schemas \
  --plugin=protoc-gen-roc=tools/protoc-gen-roc/protoc-gen-roc \
  --roc_opt=wire=../libraries/roc-protobuf/package/main.roc \
  --roc_out=generated \
  /path/to/schemas/service.proto
```

List all imported schema files as generation targets too. The `wire` parameter
is relative to the generated `main.roc`, not the working directory. For the
separate Roc bundle, replace the `--roc_opt` value with `wire=<URL>` using the wire URL in the release's `protobuf.json`.
Import `generated/main.roc` as a package from an application on any compatible
Roc platform. With only `wire`, services in schemas are ignored and generation remains
platform-free. Opt into roxum Unary registration by also supplying `grpc` and
`pf`; follow the gRPC distribution guide in the matching roxum release.
The generated service needs roxum-grpc and its matching platform; the Protobuf
wire package itself has no gRPC runtime dependency.

`setup.py` installs pinned `protoc` 33.5 and Python Protobuf 6.33.5 into
`zig-out/protobuf-codegen` within this extracted directory. It verifies upstream
artifact hashes and installs Python wheels with required hashes. Internet access
is needed on first setup. `protoc` and Python Protobuf use BSD-3-Clause licenses;
they are downloaded separately and are not embedded in either artifact. Supported tool hosts are macOS arm64/x86_64 and Linux
arm64/x86_64; runtime compatibility depends separately on the pinned Roc compiler.

## Compatibility

The library and generator are versioned together. Use both from the same release;
mixing versions is unsupported, even if generated code happens to type-check.
Regenerate code when updating the pair. `compatibility.json` records their versions,
the exact Roc revision, and the schema contract. `protobuf.json` additionally
records archive URLs, SHA-256 hashes, and expanded wire bundle size. Verify the
archive hashes before extraction. These hashes detect corruption; obtain release
metadata from the trusted release location.

`proto3-v1` supports scalar and enum fields, explicit optional presence, nested
and imported messages, repeated/packed fields, maps, real oneofs, and bounded
recursive messages. It rejects proto2, editions, extensions, weak imports, and
unsupported options. Well-known types have no supported import policy. Names
must fit the generator's Roc naming rules; collisions fail before output.
Unknown fields are validated and discarded. Unknown enum numbers are retained.
The format is not a lossless relay for schema evolution.

Recursive components share a module named after their smallest flattened message
name plus `Recursive`; singular edges within a component use `Box`. Recursive
messages and their transitive containers do not expose generated equality on the
pinned compiler. Encoders default to depth 64 and 65,536 message visits; reader
and writer limits are explicit pure values, not exact allocation or CPU quotas.

Before 1.0, increment MINOR for breaking APIs, generated layouts, defaults, or
wire behavior; increment PATCH for compatible changes. From 1.0, use MAJOR for
breaking changes and MINOR for compatible features. A compiler change requires
revalidation and an updated exact revision. Publishing these artifacts alongside
a roxum release does not establish a dependency on its core version.
