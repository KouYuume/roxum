# Fixed-byte gRPC interoperability probe

Run `python3 tools/check.py --only test-grpc-probe` or `zig build test-grpc-probe`.
The gate builds the Roc fixture with all three backends and both allocators, then
uses an independent native gRPC client over TCP and filesystem Unix sockets.

The client uses the official Python `grpcio` implementation, pinned to 1.78.2
with wheel hashes. This patched release supports the repository's Python 3.9
environment and provides wheels through CPython 3.14. `typing-extensions` is pinned
separately; installation uses a private venv and refuses source builds or
unhashed downloads. The hashes cover macOS and glibc Linux x86_64/arm64 wheels;
the Linux test container uses glibc Python even though the Roc app targets musl.

[`probe.proto`](probe.proto) describes the fixed payloads, without introducing a
schema compiler or generated bindings. `Text { value: "hello" }` is
`0a 05 68 65 6c 6c 6f`, and the reply replaces `hello` with `world`. The client
uses gRPC's raw-byte unary call API: it creates/parses the five-byte message
envelope and interprets final status independently of roxum. The Roc fixture
checks the exact request bytes and supplies fixed response bytes through `Reply`.

The checks cover:

- A successful Unary RPC's exact Protobuf bytes, `OK` status, and custom final
  metadata alongside `grpc-status`.
- An empty serialized message, which still needs a five-byte gRPC envelope.
- `INVALID_ARGUMENT` and percent-decoded error text, with no response message,
  for an explicit rejection and an unexpected fixed request payload.
- Negative controls: a missing final status fails at the client. A declared
  message length larger than the supplied payload cannot produce the expected
  message; this client may report `OK` with no message, so checking status alone
  would miss the invalid reply.
- A successful subsequent call on the same channel after each failure.

The negative controls validate the probe itself; they are not supported service
behavior. The multiple distinct short trailer values also exercise the response
bridge's retained Roc string storage. A focused Zig regression covers both
inline and heap-backed trailer values and their allocation cleanup.

This is transport evidence, not a reusable gRPC integration or Protobuf codec.
It does not implement metadata-phase Roc execution, `grpc-timeout` handling,
streaming RPCs, generated service bindings, TLS, or proxy interoperability.
An error reply has initial HTTP headers followed by final status and no message;
it does not claim a single-HEADERS trailers-only wire representation.

Protocol references: [gRPC over HTTP/2](https://grpc.github.io/grpc/core/md_doc__p_r_o_t_o_c_o_l-_h_t_t_p2.html)
and [Python Channel API](https://grpc.github.io/grpc/python/grpc.html#grpc.Channel.unary_unary).
