# Generated streaming contracts

Run `python3 tools/check.py --only test-grpc-streaming` with the pinned compiler
and Python 3.13. The check builds Unary, server-streaming, client-streaming and bidirectional services in all
three backends and both allocator modes, then uses protoc-generated grpcio clients
against production TCP and Unix listeners. Regenerate the committed service with
`python3 tests/grpc-streaming/regenerate.py --write` after changing its schema.

The upload fixture checks empty and multiple input messages, fragmented and coalesced envelopes, truncated input, and rejection before client half-close.

The generated duplex client waits for its first acknowledgement before sending its second request. A separate call receives final status while its request iterator is still open. Both half-close orders run on TCP and Unix listeners directly and through the TLS proxy. A direct HTTP/2 peer withholds stream credit after 8 KiB of a large reply. An independent observation confirms that a second request is processed while output is blocked. The peer then resets the stream or restores credit and checks the completed envelope and error trailers.

The server-streaming fixture covers ordered output, zero-message success, initial/trailing metadata,
application failure before and after output, invalid success-as-failure status,
message encoding/count/payload bounds, execution expiry after a message, and Unary
coexistence. A raw HTTP/2 client releases a producer latch only after receiving
the first complete envelope, then verifies ordered output and one final status.
It also checks the actual deadline trailers independently of grpcio's local
deadline synthesis. Multiple short header names and
values exercise the host's inline Roc-string ownership across trailer conversion.

The same assertions run through a hash-pinned nginx TLS proxy with both TCP and
Unix HTTP/2 upstreams. The example under `integrations/roxum-grpc/example` also
exercises streaming from extracted artifacts through the release verification.

`acceptance.roc` uses a separate limit profile: one concurrent writer, an 8 MiB
request-memory budget, 8 KiB messages and a two-minute duration cap. The raw
client withholds stream credit after exactly 8 KiB while returning connection
credit, and requires a Unary RPC on the same connection to complete. It repeats
16 blocked-output resets and 16 producer-wait resets, then restores credit on
another stalled stream and consumes 8,192 ordered
4 KiB messages with a 64 KiB receive window on direct listeners. The TLS-proxy
case sends 256 messages within the same 30-second absolute write deadline; it
checks proxy behavior rather than memory growth. Successful completion and a subsequent
Unary RPC check progress beyond the request-memory budget. A fresh connection
also completes a Unary RPC at every memory checkpoint while the stream remains
alive, so request cleanup cannot mask retained history. Four blocked connection
disconnects are followed by a successful stream. The worker PID set must remain
unchanged, so supervisor restarts cannot hide cleanup crashes. A new stream may
receive 503 until asynchronous cleanup releases the writer slot; the client drains
that rejection and retries within one five-second deadline. Other statuses/resets
fail immediately, and a slot leak still fails when the deadline expires.

On direct listeners, server-process-tree RSS is sampled after 1,024, 4,096 and 8,192 messages. After the
4 MiB warmup, compiled-backend samples must stay within 8 MiB of the first; this
allows bounded runtime/cache overhead while rejecting retention of the subsequent
28 MiB. Samples are printed in the check log. Interpreter RSS is recorded without that
threshold because it includes the compiler/runtime heap; its request-memory
budget and concurrent admission checks still apply. This is a bounded acceptance workload,
not a general throughput measurement or proof about application-retained history.
Existing allocator and HTTP/2 engine tests cover allocation faults and ownership;
the production fixture adds generated-message and cancellation coverage.

Linux architecture execution is recorded by the CI matrix;
a local arm64 run does not establish x86_64 runtime acceptance.
