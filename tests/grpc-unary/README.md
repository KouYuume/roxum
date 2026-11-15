# Typed Unary service checks

`service.proto` generates Roc server registration and message codecs plus an
independent Python message implementation. `regenerate.py` checks the committed
Roc output byte-for-byte after formatting; `--write` updates it.

`verify.py` calls the typed service using grpcio on TCP and Unix listeners. It
checks decoded values, binary trailers, application status text, malformed and
oversized requests, invalid application outputs, unknown methods, and successful
calls after failures. Framing and metadata parser corpora remain in
`tests/grpc-wire`; timeout parsing, pre-body expiry, stale metadata-time deadlines, and suspended
handler cancellation are covered here. Final deadline-status delivery and proxy
deployment acceptance remain subsequent work.

Run `python3 tools/check.py --only test-grpc-unary` for all backend/allocator
combinations. `test_generator.py` covers opt-in generation and atomic rejection
of unsupported descriptors; codec-only generation must stay platform-free.
