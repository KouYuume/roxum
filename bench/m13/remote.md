# Two-host runner

`remote.py` runs on the load-generator host. HTTP traffic goes directly to the
server IPv4 address. Start, snapshot, and stop commands are administrative
transports; they must not proxy the HTTP traffic. Results remain labeled
`remote-diagnostic` until the environment, generator headroom, provenance, and
A/A controls have been verified. No AWS resources are created by these scripts.

## Server preparation

All three comparison binaries use the same startup contract:

- No `benchmark-remote` file in the working directory: loopback, ephemeral port.
- File containing exactly `enabled\n`: `0.0.0.0:8080`.
- Any other content or read error: startup failure.

Create a dedicated working directory, owned by the benchmark service user, with
that file. Only enable this mode on the isolated benchmark network. Build with
`build.sh linux-native` and retain the matching build manifests.

`linux_server.py` requires Linux, systemd, cgroup v2, and root for service control.
The application itself runs as the configured unprivileged user. Reserve the
unit `roxum-http-benchmark.service` exclusively for this experiment; do not run
multiple controllers concurrently. Each trial starts a fresh service, with
whole-cgroup CPU and memory limits, no swap, and a ten-minute lifetime limit.
The duration plus warmup and control overhead must fit within that limit.

Example server configuration (`/opt/roxum-bench/roxum.json`):

```json
{
  "executable": "/opt/roxum/bench/m13/out/linux-native/roxum",
  "working_directory": "/opt/roxum-bench/work",
  "user": "bench",
  "cpus": "2-3",
  "memory_bytes": 4294967296
}
```

Create equivalent configs for axum and Go, changing only `executable`. Determine
CPU IDs from `lscpu -e` first: two hardware threads are not necessarily two
physical cores. Run single-core and multicore experiments separately.

The controller protocol is:

```sh
sudo python3 /opt/roxum/bench/m13/linux_server.py start /opt/roxum-bench/roxum.json
sudo python3 /opt/roxum/bench/m13/linux_server.py snapshot
sudo python3 /opt/roxum/bench/m13/linux_server.py stop
```

Each command emits one JSON object. Start includes binary provenance. Snapshots
include effective CPU/memory limits, CPU usage/throttling, memory usage and OOM
counters. Stop terminates the entire cgroup and returns invocation-specific logs.
MemoryPeak availability depends on the host systemd/kernel; retain raw accounting
instead of substituting a zero when a property is unavailable.
If systemd does not return `MemoryPeak`, check `memory.peak` in the service's
cgroup identified by `ControlGroup`. Checking only the cgroup root is insufficient.
A transport adapter can include this counter in the snapshot's `cgroup` object.
Use the same collection method for every candidate. Without resetting the
counter, its scope is the service lifetime, including warmup and administrative
gaps; it is not a peak restricted to measured HTTP traffic. Collect it before
stopping the service and distinguish it from the final `memory.current` value.

## Client experiment

Supply an administrative transport executable that accepts the controller action
and optional config path, invokes it on the server, waits for completion, and
returns its JSON stdout unchanged. Transport failures must return a nonzero exit
status. A transport must finish within 300 seconds or the trial fails.
The SSM transport below uses the AWS API for administration; the VPC does not
allow SSH. Do not add SSH ingress just to use this runner.

Example `experiment.json`, using a transport named `bench-server-control`:

```json
{
  "host": "10.77.0.10",
  "port": 8080,
  "budget": {"cpus": "2-3", "memory_bytes": 4294967296},
  "snapshot": ["bench-server-control", "snapshot"],
  "stop": ["bench-server-control", "stop"],
  "candidates": [
    {"name": "roxum", "start": ["bench-server-control", "start", "/opt/roxum-bench/roxum.json"]},
    {"name": "axum", "start": ["bench-server-control", "start", "/opt/roxum-bench/axum.json"]},
    {"name": "go", "start": ["bench-server-control", "start", "/opt/roxum-bench/go.json"]}
  ]
}
```

```sh
python3 bench/m13/remote.py experiment.json results.json --runs 6
```

The runner rotates order, waits for the response contract, warms up, captures
resource counters before and after load, validates the response again, and stops
the server in cleanup. Mismatched limits, OOM events, HTTP/load errors, and cleanup
failures invalidate the trial. Cleanup failure stops the experiment. Raw control
and load output are retained; existing result files are never overwritten.

A/A controls use a fourth candidate referencing the same binary and eight
repetitions. `comparison_valid` only reports trial acceptance, not environmental
fairness. Fixed-rate latency sweeps,
Linux host verification and analysis of the recorded generator counters remain prerequisites
for publishing results. Local unit tests do not validate systemd behavior.

See the [systemd-run documentation](https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html)
for transient service lifecycle behavior.

## SSM transport

`ssm_control.py` implements the administrative transport. Example invocation:

```sh
python3 bench/m13/ssm_control.py --profile <your AWS CLI profile> --region ap-northeast-1 \
  --instance i-REPLACE_WITH_SERVER_ID snapshot
```

In `experiment.json`, replace each `bench-server-control` prefix with this argv
prefix and append the action/config arguments. Alternatively, install a wrapper
that invokes it with these fixed options and forwards `"$@"`.

The client instance uses its dedicated instance role; do not copy workstation
access keys to EC2. On that host, an AWS CLI profile with the name passed as `--profile`, containing
only the region, can use the normal EC2 instance-metadata credential provider.
This is a different principal from the workstation's profile of the same name.
Verify the intended role identity during host preparation before running trials.
The Terraform client role may send `AWS-RunShellScript` only to the benchmark
server. GetCommandInvocation/CancelCommand are granted for the configured region.
The server role does not receive command-execution permissions.

Each SSM call records its command ID on stderr. The adapter handles eventual
consistency and nonterminal states, rejects failed executions, and retrieves
compressed controller output in chunks with a SHA-256 integrity check. This
avoids treating SSM's truncated stdout as complete build metadata or logs.
Per-call remote temporary files are removed after retrieval; cleanup failures
are reported. No S3 bucket or SSH connection is required. A stalled or interrupted
controller can still leave a service running until cleanup or its lifetime limit;
inspect the reserved service before restarting an interrupted experiment.

The transport is tested with local fake responses, including outputs larger than
SSM's stdout limit. An EC2 smoke test covering all six workloads also verified client-role IAM
authorization, SSM delivery, service lifecycle, effective cgroup limits, and
response checks for all three candidates. This does not establish generator
headroom or validate a comparative measurement.
See [GetCommandInvocation](https://docs.aws.amazon.com/cli/latest/reference/ssm/get-command-invocation.html)
and [SendCommand](https://docs.aws.amazon.com/cli/latest/reference/ssm/send-command.html).

## Native toolchain lock

After selecting and installing the Linux toolchains, freeze the experiment once:

```sh
python3 bench/m13/toolchain_lock.py freeze /opt/roxum-bench/toolchain-lock.json
BENCH_TOOLCHAIN_LOCK=/opt/roxum-bench/toolchain-lock.json bash bench/m13/build.sh linux-native
```

The lock records all five tool versions, architecture and relevant build flags.
Freeze refuses to overwrite a lock. Native Linux builds require this lock and
check it before and after building; the manifest embeds it. Keep the same lock
for every baseline/candidate build. This checks tool identity but does not install
compilers or make the complete native system hermetic.

## Generator counters

Load records include client monotonic timestamps for process spawning, output
collection, and JSON parsing. Client samples retain collection start/end bounds
in that same clock domain; administrative calls also retain their client-side
bounds. Server snapshots use a separate server monotonic clock. Do not subtract
timestamps across hosts. oha does not expose active-traffic/drain/output phase
boundaries in its JSON, so those traffic timestamps remain explicitly unknown.
The recorded subprocess interval is not an exact traffic interval. This timing
metadata collection and ordering were verified in an EC2 smoke test with roxum,
axum, and Go at 1,000 requests/second. That smoke test does not establish generator
headroom at saturation or resolve the unknown traffic boundaries.

The client records `/proc/stat`, load average, memory, network interface counters,
and TCP/IP counters during measured HTTP load, excluding SSM calls. Review per-CPU
utilization as well as totals, network throughput/drops, retransmissions, and EC2
network/packet allowance metrics. At least two snapshots are needed for deltas;
missing telemetry is marked invalid separately from HTTP acceptance. Raw counters
are retained without an automatic assertion of sufficient generator headroom.
The client sampler and server controller also capture optional ENA allowance
counters with `ethtool` before and after load. Missing tools or unsupported
interfaces remain explicit telemetry errors, independent of HTTP acceptance.
EC2 smoke tests verified collection for plaintext and large-body workloads.
Fixed-rate execution is available with `--rate`; remote rate sweeps and
generator-headroom validation remain necessary before latency comparisons.

## Offline diagnostic analysis

```sh
python3 bench/m13/analyze_remote.py results.json analysis.json
```

The analyzer retains per-trial latency values and reports throughput repetitions,
median, and range only when the entire experiment passed its trial gates. It
calculates per-interval CPU utilization (excluding double-counted guest time),
steal time, interface rates/errors/drops, and TCP retransmission deltas. Counter
resets, topology changes, and insufficient samples remain explicit errors.
It never certifies generator headroom. Inspect individual CPUs and intervals;
a low host-wide average can hide one saturated CPU.

For older runner results without per-trial ENA counters, also retain
`ethtool -S <interface>` before and after the experiment on both hosts. Check deltas of bandwidth, PPS, connection-tracking, and link-local
allowance-exceeded counters. Zero deltas rule out those reported limit events,
not all possible generator bottlenecks. See the
[AWS ENA metrics definitions](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/monitoring-network-performance-ena.html).

An average offered rate below the link's capacity does not exclude short bursts
that trigger bandwidth shaping. AWS documents this distinction in
[instance bandwidth monitoring](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-network-bandwidth.html).
Do not waive nonzero allowance counters merely because the requested arrival
rate was achieved. Test packet pacing separately, retaining the original failed
experiment. A changed queue discipline defines a different network environment:
record its configuration and drop counters on both hosts, apply it consistently
to every candidate, and restore the original configuration after testing.

For a completed A/A experiment, add `--aa axum axum-control`. The analyzer
requires identical binary hashes and service configurations, matching repetition
IDs, and an accepted experiment. It reports the control's median difference and
both ranges; these describe observed variation rather than statistical
significance.

## Enforce a frozen measurement

Include `measurement` in the experiment configuration to reject omitted scenario
filters or changed durations before any server starts:

```json
"measurement": {
  "scenarios": ["plaintext"],
  "runs": 8,
  "seconds": 30,
  "warmup_seconds": 5
}
```

The CLI must match these fields exactly. Scenario order follows the workload
order in `run.py`. Use this guard for recorded experiments; configurations without
it remain available for exploratory diagnostics.

## Fixed-rate latency measurements

Pass `--rate <requests-per-second>` to send the same global rate to each
candidate. The runner passes oha's `-q` and `--latency-correction`, including
during warmup, and records the actual command. Include the identical `rate` in
the frozen `measurement` object. Each rate is a separate experiment.

`offered_load.target_met` requires completed throughput to reach at least 99%
of the configured rate. This fixed threshold is separate from HTTP acceptance;
missing the target can indicate either server or generator saturation. It does
not certify generator headroom. Review raw latency, CPU, network counters and
errors at every rate, including unsuccessful rates.

An interrupted load generator is killed and reaped, its partial output is
retained, and the remote runner saves the interrupted trial after stopping the
server. The experiment exits with status 130 rather than reporting success.
