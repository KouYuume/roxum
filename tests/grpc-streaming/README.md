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

## Resource and lifecycle acceptance

`acceptance.roc` runs with two concurrent requests, one writer and an 8 MiB per-request
memory budget. Direct TCP and Unix listeners exercise these workloads:

| RPC | Workload and observable result |
|---|---|
| Server-streaming | Withhold credit after 8 KiB, complete a Unary RPC on the same connection, then restore credit and receive 8,192 ordered 4 KiB messages. Repeat resets during blocked output and producer waits, and disconnect blocked clients. |
| Client-streaming and bidirectional | Send 2,048 ordered 16 KiB payloads per call. Pause the request iterator at 4, 16 and 32 MiB. A concurrent Unary probe confirms application consumption before each RSS sample. Submit returns the final count; Chat acknowledges each checkpoint before more input is sent. |
| Interrupted input | Reset the stream or close the connection with a partial envelope after an application-observed marker. After a reset, start a new Submit on the same connection. After disconnect, use a new connection. Hold Submit open while a Unary probe confirms its marker, accounting for both request slots. A subsequent Watch must also acquire the sole writer and finish while the probe connection stays open. |
| Deadline expiry | Withhold credit partway through a duplex response. A later client-streaming deadline expires on incomplete input. Restore duplex credit and check both calls' wire status (`DEADLINE_EXCEEDED`) and the incomplete response prefix. |
| Shutdown | Signal the server after a duplex acknowledgement. On TCP, half-close after GOAWAY and require final OK and a clean exit. On Unix, keep the request open past the drain timeout and require a forced exit and a diagnostic for the cut connection. |

The server-streaming workload samples server-process-tree RSS at the same payload
sizes as the input workloads. After the 4 MiB warmup, compiled-backend samples
must stay within 8 MiB of the first sample. Interpreter RSS includes its compiler
heap and is recorded for observation. All backends enforce the request budget
and check the worker PID set before shutdown. Writer recovery allows up to five
seconds for asynchronous release, retrying only an admission rejection (503).

The TLS-proxy pressure workload uses 256 output messages within the 30-second
write deadline. Memory checks use direct listeners. The allocator and HTTP/2
engine suites exercise allocation faults and ownership separately.
