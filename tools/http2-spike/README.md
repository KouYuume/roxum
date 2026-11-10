# HTTP/2 transport spike

This disposable server checks milestone 0 of the [gRPC plan](../../docs/plans/grpc.md).
It is not a production listener or a supported Roc API. See the
[transport decision](../../docs/plans/http2-transport.md) for the design and limits.

## Run

Use the repository's [pinned Zig compiler](../../docs/toolchain.md), Python 3.9 or
later, and internet access for the pinned dependencies:

```sh
python3 tools/http2-spike/build.py
python3 -m venv zig-out/http2-spike/venv
zig-out/http2-spike/venv/bin/python -m pip install --require-hashes --only-binary=:all: -r tools/http2-spike/requirements.txt
zig-out/http2-spike/venv/bin/python tools/http2-spike/verify.py zig-out/http2-spike/server-native
```

The build verifies the nghttp2 1.71.0 release archive SHA-256, compiles only its
26 library C sources, and generates C bindings with `zig translate-c`. It does
not need CMake, a system nghttp2 installation, TLS libraries, or a Roc rebuild.
The independent client uses hyper-h2 4.3.0 with pinned, hashed dependencies.

All downloads, generated bindings, and binaries stay under `zig-out/http2-spike/`.
The build copies the current `platform/host/` sources into that directory so
`net.zig` and `fiber.zig` share a single Zig module. It recreates that snapshot
on each build; it does not modify production host sources. Run builds sequentially
because the snapshot and bindings are shared.

Cross-build the supported Linux targets:

```sh
python3 tools/http2-spike/build.py --target aarch64-linux-musl
python3 tools/http2-spike/build.py --target x86_64-linux-musl
```

Run `verify.py` with the corresponding executable on the matching Linux machine.
For the existing arm64 `roxum-linux` Docker image, the pure Python dependencies
from the host venv can also be used (adjust `python3.9` to the venv's version):

```sh
docker run --rm -v "$PWD:/work" -w /work \
  -e PYTHONPATH=/work/zig-out/http2-spike/venv/lib/python3.9/site-packages \
  roxum-linux python3 tools/http2-spike/verify.py zig-out/http2-spike/server-aarch64-linux-musl
```

## Evidence

The client checks actual wire events, bodies, and trailers:

- Two open request streams both receive response DATA before either request EOF.
- Resetting one reader leaves the other stream and connection usable.
- Completed responses include `x-spike-complete: yes` trailers and END_STREAM.
- With a 16-byte receive window, two successive 4096-byte writes force the
  handler fiber to wait for output capacity while another stream finishes.
  Resetting that stream resumes the waiting writer for cancellation and leaves
  later exchanges usable. A separate blocked writer completes after credit returns.
- Bodies of 4095, 4096, and 4097 bytes cover below/at/above the server's 4096-byte
  input window and buffer boundary. Input window replenishment permits the larger body.
- Response bodies of 15, 16, and 17 bytes cover the 16-byte output window.
  Only the 17-byte case receives additional credit; trailers complete at zero
  remaining credit, including when request EOF arrives after the body was sent.
- Disconnecting with two open readers releases both fibers.

After each connection, the server asserts that every created fiber was destroyed
and all allocations tracked by the nghttp2 session allocator were freed. Diagnostics
also count writers that return from an actual suspension through cancellation or
restored capacity; the client asserts those paths were reached. The allocation
counts are object counts, not an RSS bound or a complete host allocation audit. Callback
and option objects use nghttp2's default allocator and have separate cleanup.

The server accepts one loopback TCP connection with at most 16 simultaneous
streams and 4096-byte input/output buffers per stream. Socket operations have a
five-second timeout. It intentionally does not implement production admission,
header limits, GOAWAY drain, deadlines, TLS, Unix listeners, or Roc execution.
Do not expose it as a service or include it in release artifacts.
