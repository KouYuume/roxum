# Finite HTTP/2 acceptance

Milestone 1 of the [gRPC plan](grpc.md) is complete for finite request and
response capabilities, including concurrent-stream drain. Milestone 2 can begin
with the codec/generator inventory. This does not establish a reusable gRPC
service API or streaming RPC support.

## Gate and evidence

The gate combines production-worker tests with isolated transport and allocation
fault tests. An isolated fixture does not substitute for production scheduling.
The linked test sources contain the assertions; the README files describe how
to reproduce each group.

| Requirement | Evidence | Scope |
|---|---|---|
| HTTP/2 over TCP and Unix | [Production listener](../../tests/http2-listener/verify.py): exact echoed bodies, routing, HEAD, sequential slot reuse, and peer completion during partial input | Real supervisor, worker, Roc application, and independent hyper-h2 client |
| Final response metadata and native gRPC interoperability | [gRPC probe](../../tests/grpc-probe/README.md): exact response bytes, final status and metadata, rejected calls and subsequent channel reuse | Independent grpcio client, fixed payloads; missing status and truncated envelopes are negative controls |
| Deadlines before body completion | [Listener metadata checks](../../tests/http2-listener/verify.py): TCP notification and held permit prove BeforeBody ran before EOF; expiry/reset releases the permit and preserves peers | Generic execution controls; no host parsing of grpc-timeout |
| Independent input/output deadlines | [Connection unit tests](../../platform/host/http2/connection.zig) and listener early-reply checks: partial final output retains its timer, completed output clears only that timer, unfinished input still expires | Empty, body and trailer replies; exact clock boundaries and real TCP/Unix exchanges |
| Slow readers and backpressure | [Engine wire checks](../../tests/http2-engine/README.md): short writes, actual socket blocking, credit boundaries, writable resumption and abort; listener checks expire a zero-credit response while a HEAD peer completes | Bounded finite output, not streaming throughput evidence |
| Invalid input, exhaustion and cleanup | Engine/input/lease unit and wire checks cover field/body limits, allocation faults, rejected streams, disconnect, 15/16/17 admission and slot reuse; [ownership tests](../../tests/http2-engine/ownership_test.zig) check partial Roc cleanup | Allocation faults are injected in isolated tests; production listener exercises configured limits and cancellation |
| Draining concurrent streams | Listener admits two requests on one connection before SIGTERM; both await upstream data until GOAWAY, then return distinct bodies, HTTP 200 and one EOF each without resets | Both upstream accepts precede SIGTERM; GOAWAY last-stream ID and successful process exit are checked on TCP/Unix with and without debug |
| HTTP/1 and integration compatibility | [Standard checks](../contributing.md): HTTP/1 E2E, middleware stages, integrations and compatibility manifest | No public ABI layout changes in metadata dispatch |

## Verification baseline

The implementation baseline is commit `695c2c4fa0fdd8c87c5ca897bfd962338dc04038`,
merged through PR #42. Its committed-tree macOS arm64 full suite passed all
567 jobs, including the six backend/allocator combinations. Linux arm64 checks
passed unit, semantic ABI, HTTP/2 wire, ThreadSanitizer, and all six listener and
gRPC-probe variants. Linux's existing file-permission test skips when run as root.
These baseline results do not claim a complete Linux release-suite run. x86_64 runtime
execution is not established by these results; supported-target builds are not
runtime evidence for that architecture.

Reproduce the affected checks with the pinned [toolchain](../toolchain.md):

```sh
zig build test test-abi test-http2-wire
python3 tools/check.py --only test-http2-listener
python3 tools/check.py --only test-grpc-probe
bash tools/linux/test.sh zig build test-tsan
```

Before publishing implementation changes, also run the committed-tree complete
suite required by [contributing](../contributing.md).

## Concurrent-stream drain verification

The production listener check now admits two requests on the same connection.
Each connects to a test upstream that withholds its response. Both connections
must be accepted before SIGTERM starts draining. The client observes GOAWAY
before supplying distinct upstream bytes, then checks both HTTP 200 responses,
exact payloads, one EOF per stream, absence of resets and successful process exit.
This exercises simultaneous unfinished requests rather than combining separate
single-stream drain and peer-progress results.

`python3 tools/check.py --only test-http2-listener` passed on macOS arm64 and
through `tools/linux/test.sh` on Linux arm64 for this extension. Both runs cover
all three backends and both allocators, TCP/Unix, and normal/debug operation.
The host implementation is unchanged; these runs extend the baseline evidence
with the previously missing concurrent-stream case. They are focused checks,
not new complete release-suite runs.

## Capability boundary

Input is bounded and collected through EOF before body bytes are delivered.
BeforeBody can run earlier; ordinary body handlers cannot. HTTP/2 response writers,
file streams, incremental receive credit and full-duplex exchange remain later work.
The gRPC probe neither generates codecs nor implements grpc-timeout parsing,
service registration, compression or single-HEADERS trailers-only replies.
TLS/proxy interoperability belongs to the Unary integration gate, not this gate.

Next, inventory reusable Roc Protobuf implementations and generator options against
milestone 2's schema, ownership-independent pure codec and bounded decoding
requirements. Record supported and rejected schema features before implementing a
codec or choosing a generator dependency. Do not move Protobuf or gRPC status
policy into the host to complete that work.
