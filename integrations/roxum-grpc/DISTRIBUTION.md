# Using the gRPC distribution

A release containing the gRPC integration supplies three Roc bundles: the roxum
platform, `roxum-grpc`, and `roc-protobuf`. `release.json` names their URLs and
SHA-256 hashes. Its `protobuf.source` entry identifies the source archive containing
the matching `protoc-gen-roc` generator and pinned setup tools. Use the platform
URL from that same release everywhere: the application, integration and generated
service package must agree on platform identity.

Install the Roc compiler named by the release's `protobuf.roc_release` (built from
`protobuf.roc_revision`). Download release metadata from the trusted release
location, verify artifact SHA-256 hashes before extraction, and use the generator
and wire library from the same release. The integration's version and
`platform_versions` are recorded in `release.json`; compiler identity is stricter
than the version range.

## Build a service outside the checkout

Copy the [example](example/README.md) from the matching release tag: files `app.roc`, `service.proto`, `generate.py`,
`client.py` and `requirements.txt` into a new directory. Extract the verified
Protobuf source archive into a separate `tools-source` directory. These steps do
not require any local roxum platform or library source.

Install the generator and independent Python client dependencies:

```sh
python3 tools-source/tools/protoc-gen-roc/setup.py
python3 -m venv .venv
.venv/bin/python -m pip install --require-hashes --only-binary=:all: -r requirements.txt
```

In `app.roc`, replace the local `pf`, `grpc` and `wire` dependency paths with the
actual URLs in `release.json`. Keep `service: "generated/main.roc"`. Generate the
bindings using those exact same URLs (replace the placeholders below):

```sh
.venv/bin/python generate.py \
  --tool-root tools-source \
  --platform '<release.platform.url>' \
  --grpc '<roxum-grpc integration URL>' \
  --wire '<release.protobuf.wire.url>' \
  --python-output python-client
roc build --output=server app.roc
./server
```

In another terminal, use the printed port:

```sh
.venv/bin/python client.py 127.0.0.1:PORT --bindings python-client
```

Python, protoc and grpcio are needed for generation and the example client. The
built server runs independently. See the [example](example/README.md) for direct
TLS with core 0.4 and the [reverse proxy guide](../../docs/guides/reverse-proxy.md#native-grpc-over-tls)
for TLS termination in front of a cleartext listener.

## Release compatibility and verification

The example calls unary, server-streaming, client-streaming and bidirectional
methods. For supported
message types, see the [schema contract](../../libraries/roc-protobuf/DISTRIBUTION.md#compatibility).

`zig build test-m13a` verifies the release metadata and hashes, installs the
extracted generator, and builds this service outside the checkout. It runs the
client over both cleartext HTTP/2 and direct TLS with dev and speed builds.
Each build uses a fresh cache so that all three
bundles must be fetched by URL. The example requests two server threads.
For interpreter coverage with a single thread, see the
[streaming acceptance suite](../../tests/grpc-streaming/README.md).
