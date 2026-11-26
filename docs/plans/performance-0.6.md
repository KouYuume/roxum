# 0.6 — HTTP performance against axum

The release target is comparable HTTP throughput and tail latency under equal
resources. If a reproducible Roc constraint prevents that, 0.6 can close the
performance phase with a measured gap and a testable condition for resuming
work. This plan covers HTTP/1.1 on native Linux. Claims apply only to the
workloads and budgets measured.

## 1. Define equivalent work and freeze the decision

Start from the released `v0.5.0` platform and its pinned toolchain. The
[historical measurements](../performance.md) found a routing throughput ratio
of 0.73 on two cores with an earlier Roc compiler. They give a reason to
investigate routing, but give no estimate for 0.5 or for dynamic handlers.

The roxum and axum benchmark apps implement three primary workloads. The
[runner contract and fixture setup](../../bench/m13/protocol.md#06-workloads)
describe the requests and pre/post checks. Use the same benchmark sources
against the released platform and the optimization candidate.

| Workload | Observable work to check |
|---|---|
| Existing routing | Match one of 100 routes, extract the path parameter and return its value. Retain the existing route and connection settings. |
| Dynamic JSON with middleware | Read a request header in middleware and a path parameter in the handler. Serialize both values into a JSON response per request. Vary both inputs in contract checks and verify the response and middleware header. |
| File serving | Serve the same 64 KiB file from a warmed filesystem cache on each server. Check the status, length and complete contents. Record bytes/s alongside completed requests/s. |

Run the existing fixed-response and echo workloads as diagnostic controls.
Use the [comparison protocol](../../bench/m13/protocol.md) and
[two-host procedure](../../bench/m13/remote.md) at one and two physical cores
with the same 4 GiB limit. Freeze the route mix, concurrency, toolchain locks,
production builds, resource settings, and maximum trial budget before confirmation.
Calibrate with separate pilot data. For each workload and CPU budget, fix a
common arrival rate at 70% of the slower pilot saturation throughput for the
p99 test. Keep that rate for before/after comparisons. Validate generator and
network headroom at the fastest candidate's rate, including for file transfers.

**Proposed 0.6 decision rule.** Confirm the margins before collecting comparison
data. For every primary workload at both budgets, require the lower bound of the
95% paired interval for roxum/axum saturation throughput to be at least 0.95,
and the upper bound for the fixed-rate p99 latency ratio to be at most 1.05.
Faster results qualify. Compute ratios within balanced repetition blocks and
use per-trial p99s for latency. Apply the protocol's response, offered-rate and
error gates. Inspect whole-service peak memory and CPU/request and freeze
regression limits for retained changes during calibration. Report each cell
separately. An interval crossing a margin leaves that metric unresolved.

## 2. Establish the baseline and improve roxum

1. Publish a baseline table with both ratios, intervals, absolute values,
   memory and CPU/request. Retain raw trials, failed runs, binary manifests,
   experiment settings and the identical-binary control. If the control lacks
   resolution or the network limits a workload, fix the measurement first.
2. Select the largest confirmed shortfall. Profile the full service at matched
   useful load. Separate host scheduling, syscalls, parsing and file I/O from
   Roc dispatch, allocations, copies and generated code. Normalize by completed
   requests. The [investigation guide](../../bench/m13/investigation.md) lists
   diagnostics and their limits.
3. Test one explanation at a time. Compare an idiomatic roxum change against
   the unchanged binary in interleaved, uninstrumented runs. Preserve response
   semantics, ownership, cancellation and admission behavior. Keep changes
   with a repeatable benefit and acceptable effects on the other workloads,
   p99 and memory. Reprofile the residual gap before choosing the next change.

## 3. Decide whether to release or resume investigation

If all cells pass, publish the results and scope in [performance status](../performance.md).
If a cell misses, a profile pointing into Roc is only the start of attribution.
For each gap proposed for deferral, record the following evidence together:

- **Cause and owner.** Reduce the expensive operation to a runnable example on
  the pinned revision. Identify the relevant language or ownership rule, ABI
  contract, compiler code generation, or runtime behavior. Link the rule or
  implementation. Compare at least one valid Roc formulation and investigate
  host-side alternatives that preserve the public contract.
- **Impact.** Measure the operation per request on the affected path. Use a
  controlled diagnostic variant to isolate its cost, then check the predicted
  direction and magnitude against the end-to-end gap. Label any variant that
  skips required work as diagnostic only. Account for other material costs
  before attributing the remaining shortfall to Roc.
- **Reopening test.** Name the capability or change needed, the reproducer
  command, the current result and a numerical threshold derived from that
  workload's gap. For example, if a required copy dominates, record bytes
  copied per request and the reduction needed at the same payload size.
  Specify which paired workload and budget to rerun when a candidate compiler,
  ABI change or contract-preserving roxum design passes that test.

Close 0.6 with a documented constraint only when every missed target has this
evidence and reopening test, and the affected correctness checks pass. A noisy
measurement, an unexplained gap or a viable untested roxum fix keeps the
investigation open. For either release outcome, publish the accepted changes,
remaining gaps and reproduction details, and run the normal
[release verification](../contributing.md#before-pushing).
