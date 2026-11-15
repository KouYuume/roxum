# gRPC wire integration checks

See the [package contract and commands](../../integrations/roxum-grpc/README.md).
The application echoes serialized bytes on a finite HTTP/2 listener; grpcio
supplies native Unary framing and a separate h2 client supplies malformed or
fragmented envelopes. The deterministic corpus seed is retained in `verify.py`.
Both clients assert actual response payloads and final statuses. Dependency
hashes reuse the existing gRPC probe and HTTP/2 client locks.

This fixture tests the protocol foundation, not generated service dispatch,
deadline enforcement, streaming RPCs, or proxy deployment acceptance.
