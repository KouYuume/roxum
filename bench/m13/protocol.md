# HTTP comparison protocol

The purpose is to find reproducible costs, including regressions in roxum. A
result that favors another implementation is a useful result. Apply the same
acceptance rules to every implementation and retain failed trials.

## Two kinds of measurement

- **Local diagnostic:** server and load generator share a host. Useful for
  checking the harness and investigating a change; not a publishable ranking.
- **Comparative measurement:** dedicated Linux server and separate load
  generator, with fixed CPU and memory budgets and sufficient network capacity.
  Record both machines and monitor client saturation before attributing a limit
  to the server. Nonzero ENA bandwidth or packet allowance-exceeded deltas identify
  network-constrained trials; do not report their throughput as an application
  processing limit. Retain them and use a separately frozen environment or load
  configuration to investigate. Container networking and virtual machines are separate test
  environments, not substitutes for native results.

The current `run.py` executes local diagnostics. It records executable and load-tool
hashes, the runner hash, the tracked benchmark/platform patch, runtime environment
overrides, descriptor limits, and CPU affinity where available. Matching build manifests are embedded when available; missing provenance stays explicit
as an empty list. Machine isolation still requires the experiment record below. The remote runner and resource
isolation must be validated before publishing comparative results.

## Freeze the experiment before measuring

Record source revisions (including dirty patches), exact compiler and load-tool
versions, dependency lockfiles, build commands and flags, binary hashes, OS,
CPU architecture and topology, RAM, power settings, kernel, CPU affinity,
process/thread counts, file-descriptor limits, and network topology. Pin build
images by digest; `rust:1` and similar moving tags are not reproducible inputs.
Build all candidates before the trial sequence, with production optimizations.
Select supported production compiler releases for each candidate and record any
compatibility constraints. A minimum language version (such as `go.mod`'s `go`
directive) does not require that old compiler. Label older toolchain experiments
as historical baselines; freeze a new experiment when changing toolchains.

Compare both a one-core budget and an equal multicore budget. Count the whole
process tree, including roxum's supervisor and workers. Apply the same CPU quota
and memory limit to every server; do not equate process count with CPU budget.
Keep logging, compression, protocol, connection reuse, body limits, and request
semantics consistent. Document unavoidable differences rather than quietly
changing only one implementation. Keep default and tuned configurations in
separate experiments and give every implementation the same tuning opportunity.

## Workload contracts

| Scenario | Contract | Interpretation |
|---|---|---|
| plaintext | GET `/plaintext`, 200, `Hello, World!`, text/plain | Fixed response overhead |
| json | GET `/json`, 200, `{"message":"Hello, World!"}`, application/json | **Pre-encoded JSON**, not serialization performance |
| routing | GET `/r57/items/42`, 200, `42`, text/plain; 100 routes | Path lookup and extraction |
| large-body | POST `/echo`, 32 KiB, 200, identical bytes, application/octet-stream | Buffered upload and echo |
| keep-alive-heavy | Plaintext, 16 concurrent connections | Lower concurrency |
| many-connections | Plaintext, 1000 concurrent connections | Higher concurrency |

These are workload classes, not API validation boundary tests. Validate status,
body, and media type before and after every trial. Validate correctness separately
under concurrent load with the integration tests; a throughput tool checking
status codes is not a complete correctness test.

Dynamic JSON serialization, middleware, streaming, and database workloads must
have their own equivalent contracts before being added. Do not describe the
fixed JSON test as general API or DDD performance.

## Trial procedure and acceptance

1. Freeze duration, warmup, repetitions, workload order, resource budgets, and
   acceptance rules before seeing comparative results. Start with six repetitions,
   30 seconds of measurement, and five seconds of warmup; extend all candidates
   equally if variation is excessive.
2. Start a fresh server for each trial and verify its response. Apply actual
   warmup traffic, then measure the same workload without restarting the server.
3. Rotate candidate order across repetitions. Include a duplicate of a baseline
   binary under a different label as an A/A noise control. Increase repetitions
   to a multiple of candidate count for balanced order positions.
4. Save raw load-tool output, commands, timestamps, failures, and server logs
   after each trial. A failed trial invalidates the experiment's comparison;
   retain it and investigate rather than dropping it from the summary.
5. Require positive completed request counts, only the expected HTTP status,
   zero transport errors, and valid pre/post responses. Drain requests at the
   duration boundary rather than hiding deadline cancellations. An invalid
   result must not enter throughput or latency summaries.
6. Report every repetition, throughput median and range, and per-trial latency
   percentiles. Do not average percentiles or pair the best throughput with the
   best latency from another trial. A small gain within A/A variation is inconclusive.

The fixed-concurrency test measures saturation, not latency at a fixed arrival
rate. Add a separately configured rate sweep for latency/SLO claims, with
coordinated-omission correction and verification that the generator sustains the
offered rate. See [oha](https://github.com/hatoo/oha) and
[wrk2's measurement discussion](https://github.com/giltene/wrk2).

## Improvement loop

Save an immutable baseline, identify a reproducible weak workload, then profile
server CPU, allocation, I/O waits, and scheduling with an equal resource budget.
Make one change at a time. Re-run the same experiment interleaving baseline,
candidate, and A/A control. Accept an optimization only after correctness tests
pass and the benefit exceeds control variation without unacceptable regressions
in other workloads, memory, or tail latency. Publish regressions and tradeoffs.

Compilation benchmarks are a separate experiment: report clean builds and
incremental application edits independently, include cold/warm cache state, and
state whether the host and dependencies were prebuilt.

## Running the local diagnostic

Build the three servers before running the experiment:

```sh
bash bench/m13/build.sh macos
python3 bench/m13/test_runner.py
python3 bench/m13/run.py --runs 6 --seconds 30 --warmup-seconds 5 \
  oha bench/m13/out/local-comparison.json \
  roxum=bench/m13/out/macos/roxum \
  axum=bench/m13/out/macos/axum \
  go=bench/m13/out/macos/go
```

For an A/A control, add another label pointing at the identical binary and choose
repetitions divisible by the new candidate count. For a harness smoke test, use
`--runs 1 --seconds 1 --warmup-seconds 1`; never publish its throughput as a
comparison. `--scenario plaintext` selects one workload and can be repeated.

Outputs are never overwritten. Schema version 2 retains the full trial records
under `samples`, including warmup and raw load-tool output. `comparison_valid`
means the local trials passed the correctness/error gates; `kind` remains
`local-diagnostic`, so this flag does not certify environmental fairness.
The JSON case is still named `json` for compatibility with existing scripts.

## AWS environment

See [the two-host Terraform environment](aws/README.md) for infrastructure, cost,
verification, cleanup, and the remaining remote-runner work. Provisioning hosts
alone does not establish a valid performance comparison.

## Build provenance and local memory diagnostics

`build.sh` writes `build-manifest-<target>.json` beside the executables. It records
native compiler versions, compiler launcher hashes, source hashes (including
untracked benchmark sources), relevant build environment variables, and output
binary hashes. The runner embeds only manifests matching the binary being run.
A binary copied without its manifest has no recorded build provenance.

Docker builds resolve the image to its immutable repository digest before use.
For a repeat experiment, set `GO_IMAGE` and `RUST_IMAGE` to the recorded digests;
leaving the defaults selects from mutable tags again. The build script is included
in the source hashes. Native Linux builds now require a shared toolchain-version lock (see remote.md).
This does not capture every external dependency of the native build.

On the Linux server, `bash bench/m13/build.sh linux-native` builds all candidates
natively with the installed Roc, Zig, Rust, and Go toolchains. Install and freeze
those toolchains before the experiment. The split `linux` / `linux-deps` workflow
writes separate manifests so one build cannot replace the other's provenance.

Each measured local trial also samples the server root and all descendants once
per second. `process_metrics.valid` is independent of the HTTP acceptance flag;
failed snapshots are reported, never converted into zero memory usage. Sampling
runs on the shared diagnostic host and adds overhead. Summed RSS counts shared
pages in each process and its sampled peak can miss short-lived allocations.
Use it for diagnosis, not a claim about unique physical memory or an exact peak.
The older `memory.py` remains a worker-only debugging tool.

The default is six repetitions, balancing three candidates. Adding an A/A control
creates four candidates: use eight repetitions to balance them. Unbalanced runs
are explicitly marked and produce a warning, while short smoke tests remain
available. The [remote runner and Linux cgroup controller](remote.md) implement lifecycle
and resource checks. An EC2 smoke test covered all six workloads for all three candidates and verified
SSM delivery, service lifecycle, and effective cgroup limits. Longer repetitions,
generator headroom, and A/A controls remain prerequisites for comparative measurements.
