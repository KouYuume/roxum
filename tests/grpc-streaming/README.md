# Generated server-streaming contracts

Run `python3 tools/check.py --only test-grpc-streaming` with the pinned compiler
and Python 3.13. The check builds a mixed Unary/server-streaming service in all
three backends and both allocator modes, then uses protoc-generated grpcio clients
against production TCP and Unix listeners. Regenerate the committed service with
`python3 tests/grpc-streaming/regenerate.py --write` after changing its schema.

The fixture covers ordered output, zero-message success, initial/trailing metadata,
application failure before and after output, invalid success-as-failure status,
message encoding/count/payload bounds, execution expiry after a message, and Unary
coexistence. A raw HTTP/2 client releases a producer latch only after receiving
the first complete envelope, then verifies ordered output and one final status.
It also checks the actual deadline trailers independently of grpcio's local
deadline synthesis. Multiple short header names and
values exercise the host's inline Roc-string ownership across trailer conversion.

This is the first server-streaming integration gate. TLS-proxy deployment,
sustained memory plateau, slow-reader pressure and cancellation stress belong to
the next production acceptance gate. Incremental request input, client-streaming
and bidirectional RPC are not enabled by this fixture.
