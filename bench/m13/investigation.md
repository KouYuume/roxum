# Diagnosing performance before optimizing

Use this workflow with [the comparison protocol](protocol.md) and
[the remote runner](remote.md). Profiling identifies hypotheses; an uninstrumented,
controlled experiment decides whether an implementation change helps. Keep
experiment results and machine identifiers in ignored local reports.

## Separate three questions

1. **Did the experiment run correctly?** Validate responses, errors, resource
   limits, cleanup, provenance, and complete trial retention.
2. **Can this experiment resolve the effect of interest?** Quantify repeatability,
   time/order effects, uncertainty, and generator/network limitations.
3. **What caused the cost?** Attribute CPU work, allocation, copying, system calls,
   and waiting to a request path under a defined workload.

Passing the first gate does not answer the other two. An inconclusive result is
neither proof of no improvement nor proof that the environment cannot measure it.
The difference between two A/A label medians is a diagnostic, not a confidence
interval or a permanent resolution floor.

## Calibrate the measurement

Before a new experiment, freeze the primary metric, minimum worthwhile effect,
uncertainty method, workload, order seed, repetitions, maximum measurement budget,
and regression limits. Keep calibration data separate from confirmation data.
Do not replace an earlier experiment's acceptance rule after seeing its result.

Use short time blocks containing both variants, with a precomputed balanced,
randomized order. Include identical-binary controls. Analyze differences or log
ratios within blocks and account for the blocking; do not treat individual HTTP
requests as independent experimental replications. Examine serial dependence
and repeat selected blocks in another session. Choose repetitions from pilot
variance and the desired resolution, rather than extending until a favorable
result appears. Longer trials alone do not remove between-start or host drift.

Report an effect estimate with an interval and its assumptions. An interval that
includes both no improvement and a useful improvement is inconclusive. A claim
that a useful improvement is absent needs an interval narrow enough to exclude
that effect. A/A checks remain useful for detecting bias even when inference is
based on paired differences. See [NIST on paired comparisons and effect
thresholds](https://www.itl.nist.gov/div898/handbook/eda/section3/eda353.htm) and
[blocking](https://www.itl.nist.gov/div898/handbook/pri/section3/pri332.htm).

## Make the observation windows explicit

Record monotonic timestamps for warmup, administrative snapshots, load process
start, active traffic, drain, output processing, and process exit. If the load
tool cannot expose traffic phase boundaries, record that limitation; elapsed
time since sampler startup is only an approximation.

Collect low-overhead server and client samples locally during load. Include
per-thread CPU, run-queue delay or scheduler evidence, CPU migrations, cgroup
usage/throttling/pressure, host steal time, and memory current/peak where supported.
Record unavailable counters explicitly. Keep the same collection policy for all
candidates and measure its overhead separately.

The current client sampler surrounds the entire load-tool subprocess, including
output processing. The remote server snapshots surround administrative transport
gaps as well as load. Neither window alone supports exact per-request cost
attribution. Preserve the full windows rather than deleting inconvenient samples.

Keep affinity, CPU quota/period, thread topology, and interrupt activity visible.
Nonzero `cpu.stat` throttling is evidence of scheduling constraints, not proof of
their causal contribution to a regression. Do not remove a quota only for roxum.
A quota or topology experiment needs a separate frozen configuration applied
equally to all relevant candidates. See the [cgroup
documentation](https://docs.kernel.org/admin-guide/cgroup-v2.html).

Validate generator headroom with a separate capacity experiment: increase its
available CPU or use multiple load processes while keeping aggregate offered
rate/concurrency and server conditions fixed. Combine invariance of server results
with per-thread observations and achieved offered rate. Low host-average CPU or
zero HTTP errors alone is insufficient. Zero [ENA allowance
increments](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/monitoring-network-performance-ena.html)
excludes those recorded limits, not every possible network bottleneck.

## Attribute costs before changing code

Use a separate diagnostic run at a repeatable load. Normalize counts by completed
requests in the same observation window. Count the supervisor and worker process
tree; do not accidentally profile only an idle supervisor. For kernel networking,
also inspect the server CPUs: asynchronous softirq work may not be attributed to
the application cgroup. Report scope and possible unrelated host activity.

Use [`perf stat`](https://raw.githubusercontent.com/torvalds/linux/master/tools/perf/Documentation/perf-stat.txt)
for task-clock, context switches, migrations, faults, and supported hardware
counters. Retain unsupported events and multiplexing coverage. Use sampled call
stacks and instruction/source attribution to connect hot symbols to operations.
Sampling percentages are relative costs, not removable savings; inlining can
attribute several operations to one symbol.

| Area | Diagnostic and workload | Change justified only after |
|---|---|---|
| Request construction, allocation, cleanup | Allocations and bytes/request, copied bytes/request, call stacks; parsed-head-to-Roc-value microbenchmark including cleanup; HTTP workloads with varied headers/body | Repeated work is demonstrated and ownership/lifetime tests cover its removal |
| Request IDs and clocks | System-call counts/request and call sites; separate timing of secure random filling and formatting; plaintext | A measurable avoidable cost is identified; randomness, fork isolation, tracing, deadlines, and cancellation remain correct |
| Dispatch, queues, locks, fibers | Queue delay, run-queue delay, lock/off-CPU evidence, migrations and CPU/request; one/two-core and concurrency sweeps | Waiting or coordination is a demonstrated limit, rather than useful application work |
| HTTP parsing and framing | Parser CPU/request, branch/copy counts; valid and invalid inputs across sizes and fragmentation | Duplicate work or an inefficient path is located without weakening validation, limits, or request-smuggling defenses |
| Routing | Lookup cost versus route count, sibling fan-out, depth and hit/miss position | Scaling is demonstrated under the routing workload; matching precedence and tags/layers remain unchanged |
| Response and network I/O | Writes, packets and bytes/request, encoding/copy costs, ENA events; plaintext and body-size sweep | Application cost is separated from network limits; backpressure and streaming semantics remain intact |

For internal counts, prefer thread-local aggregation and export after the run.
Avoid adding a clock read or shared atomic to every request just to measure a
small existing cost. Instrumented binaries and microbenchmarks are diagnostic
artifacts, not replacements for uninstrumented end-to-end confirmation.

## Confirm one causal hypothesis

Write the predicted mechanism and affected workload before changing code. A
microbenchmark can establish a local cost reduction; it cannot establish HTTP
throughput improvement. Confirm the change with an uninstrumented A/B experiment,
then test affected workloads, fixed-rate latency, memory, and correctness.

Keep default-framework comparisons separate from feature-matched comparisons.
For example, request-ID generation can be an intrinsic default cost even when the
plaintext body is identical. Disclose it; do not silently disable it only for one
candidate. A feature-matched suite must give all implementations the same feature
contract and tuning opportunity. Never remove validation or security guarantees
to improve a benchmark number.

Stop an investigation when the predeclared budget is exhausted or the interval
rules out a worthwhile benefit. Retain unfavorable and inconclusive results.
Only confirmed changes advance to the complete cross-framework comparison.

## Local request-construction diagnostic

Run from the repository root with the pinned Zig compiler:

```sh
zig run -O ReleaseSafe -lc --dep bridge --dep heap \
  -Mroot=bench/request_bridge.zig \
  -Mbridge=platform/host/bridge.zig \
  -Mheap=platform/host/allocator/request_heap.zig \
  2> request-bridge.csv
```

Keep the CSV outside version control. It records six repetitions in alternating
case order, with 100,000 constructions and generated-glue cleanups per case.
Parsing the HTTP bytes occurs outside the timed loop. Admission head validation,
owned request construction, allocation counters, leak checks, and cleanup occur
inside it. A cached production request heap and host allocation prefixes are used;
no Roc handler, socket, fiber switch, or random-ID generation runs. The supplied
32-byte request ID still incurs its normal conversion cost.

The cases separate header fan-out (1, 8, 64), the 64-bit Roc inline-string boundary
(path lengths 23, 24, 25), a nonempty query, and a 4,095-byte path with a one-byte query. These are diagnostic dimensions,
not an exhaustive HTTP contract matrix. Requested allocation bytes include Roc
reference-count headers but exclude host prefixes and heap rounding. Heap peak
bytes include the allocator's live allocation accounting, not process RSS or
retained cache capacity. The counters do not count copied bytes or underlying
page allocations. Every iteration requires both live allocation counts and heap
live bytes to return to zero.

Use allocation counts to locate costs and timing only as an instrumented local
diagnostic. There is no warmup exclusion; all repetitions, including cold cases,
remain in the output. Do not compare these times with HTTP throughput or present
them as evidence of an optimization without a separate baseline and candidate.

After each timed sample, a separate untimed construction retains only the query,
releases the request, and records `query_retained_heap_bytes`. This detects when
sharing reduces allocation count but prolongs the lifetime of a larger backing
allocation. Releasing the last query must again leave zero live allocations.
The retained-byte count is heap accounting, not RSS; the cached heap may retain
free pages after all values are gone.

For a built `bench/m13/app.roc` server, verify path handling over HTTP before a
performance experiment:

```sh
python3 bench/m13/check_paths.py /path/to/server /path/to/new-results.json
```

This checks valid captures, dot segments, repeated slashes, query isolation, and
request-target lengths 8,191 / 8,192 / 8,193 bytes. It checks response bodies for
successful requests and status codes for rejected requests, and retains failures.
Run it against both binaries. A passing check is a correctness observation, not
a measurement of throughput or a substitute for the broader HTTP contract suite.

## Instruction counts per request

`instructions.py` locates costs without a PMU or a second machine. It runs each
server under callgrind twice, for 2,000 and 12,000 requests from oha with the
scenario's connection count, and divides the difference in user-space
instructions by the difference in requests, so startup, warmup and shutdown
cancel. Counts are summed over all processes the server forks and grouped into
subsystems by source file (inlined code keeps its own file).

```sh
bench/m13/profile/run.sh python3 bench/m13/instructions.py --scenario plaintext \
  /oha reports/<name>.json roxum=bench/m13/out/linux/roxum axum=bench/m13/out/linux/axum
```

`profile/run.sh` extends the Linux test image with valgrind, perf and strace and
mounts a Linux oha binary (`OHA_BINARY`) at `/oha`. Repeated runs of the same
binary agreed within 0.4%, so a change in instructions/request can be checked
locally before an uninstrumented throughput experiment. The scheduling and
locks row varies the most, by up to about 500 instructions/request between
runs of one binary, because valgrind's serialization of threads changes how
often the loop polls; repeat a run before reading a change there. Valgrind serializes
threads: the count excludes kernel work, waiting and contention, and it is not a
throughput or latency measurement. Callgrind's inclusive costs are unreliable
across fiber switches and recursion; use the self-cost rows. Valgrind 3.19
faults while starting the Go server on arm64, and that row is recorded as
invalid. Docker Desktop's VM exposes no hardware counters to `perf stat`.

Callgrind counts instructions, not their cost. On EC2, a change that removed
20% of roxum's user-space instructions removed 7.5% of its user-space cycles:
the work removed was cheap, and stalls, clock reads through the vDSO, and
kernel time (half of all cycles there) are invisible to it. Treat a reduction
in instructions/request as a reason to measure, not as a predicted speedup, and
confirm with `perf stat` cycles (user and kernel) and throughput. Work that runs
per unit of time is also counted per request: the loop's timer tick scans every
connection slot, which valgrind's slowdown inflates to about 1,100
instructions/request although natively it is negligible.
