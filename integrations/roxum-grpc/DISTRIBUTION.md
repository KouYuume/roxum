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
than the version range. Existing releases without these artifacts do not acquire
Unary support from this guide.

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

Python, protoc and grpcio are build/client tools, not dependencies of the resulting
server executable. The generated codecs use the pure Roc wire library; request
handling and status policy live in the integration. The host owns HTTP/2 transport
and execution lifetimes. See [TLS deployment](../../docs/guides/reverse-proxy.md#native-grpc-over-tls)
for production ingress.

## Supported scope and release evidence

The 0.3 example exercises Unary, server-streaming, client-streaming and
bidirectional RPC. The 0.2 release supports Unary only. Server reflection, gRPC-Web and compressed messages are not provided. The
[schema contract](../../libraries/roc-protobuf/DISTRIBUTION.md#compatibility) applies
to generated messages; supplying `grpc` and `pf` explicitly enables typed service
registration. Codec-only generation continues to ignore services.

`zig build test-m13a` builds actual release artifacts, checks metadata and hashes,
installs the generator from its extracted source archive, generates this service
outside the checkout, and runs its client against all three compiler backends.
Each build uses fresh caches and must fetch platform, gRPC and wire bundles by
URL. `test-grpc-example` verifies the source example across both allocators;
`test-grpc-unary` and `test-grpc-streaming` cover direct and TLS-proxied protocol
behavior. Publishing and release version selection remain maintainer operations.
