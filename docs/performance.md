# Performance status

roxum aims for throughput and latency comparable to axum under equal resources
and equivalent work. It does not reach that yet. This page records where it
stands, how that was measured, and what is known about the gap. Measurements are
not repeated for every change; the date and revision of each result are given.

## Fixed-response HTTP throughput

Measured on 2026-11-06, with that day's improvements to the per-request cost.

| Workload | Connections | roxum req/s | axum req/s | roxum / axum (95% interval) |
|---|---:|---:|---:|---|
| plaintext | 64 | 216,198 | 262,406 | 0.82 [0.80, 0.84] |
| json (pre-encoded) | 64 | 218,086 | 263,277 | 0.83 [0.82, 0.84] |
| routing (`/r57/items/42` of 100 routes) | 64 | 187,479 | 257,266 | 0.73 [0.72, 0.73] |
| keep-alive-heavy | 16 | 172,320 | 179,449 | 0.96 [0.89, 1.05] |
| many-connections | 1000 | 200,752 | 264,590 | 0.76 [0.74, 0.79] |

Throughput is the median of four trials. Intervals are 95% t intervals of the
per-repetition log ratio. The p99 latency, as the median of the trials' p99
values, was:

| Workload | roxum | axum |
|---|---:|---:|
| plaintext | 0.48 ms | 0.35 ms |
| routing | 0.55 ms | 0.36 ms |
| many-connections | 9.9 ms | 24.5 ms |

A 32 KiB echo at a fixed 5,000 requests/s used 35–37 µs of server CPU per
request for roxum and 32–33 µs for axum. Its throughput at saturation is not
reported: there, both reached the instances' network bandwidth allowance, which
does not measure the server.

In the same session, roxum without those improvements ran plaintext at 206,970
req/s. The improvements made it 1.044 [1.029, 1.059] times as fast, and a
copy of the same binary under another label measured 1.001 [0.971, 1.033].

## Conditions

- AWS ap-northeast-1, one cluster placement group. The server was a
  c7i.2xlarge (Xeon Platinum 8488C) and the load generator a c7i.4xlarge.
  Traffic used private addresses directly; the server's 8080 was the only
  inbound port.
- Each server ran in a fresh systemd service limited to CPUs 2–3 (two physical
  cores), a 200% CPU quota, 4 GiB of memory and no swap.
- oha 1.16.0 over HTTP/1.1, 20 seconds after 5 seconds of warmup. Four trials
  per server and workload, with the order of servers rotated. Every trial
  returned only 200 responses with no errors.
- Toolchains: Zig 0.16.0 and Roc nightly-2026-10-18-1df370f (the pinned ones),
  Rust 1.99.1. roxum's host is built ReleaseSafe; axum in release mode with LTO.
- Both servers run the routes in `bench/m13/app.roc` and `bench/m13/axum`.
  These are fixed responses. The json workload sends a pre-encoded body and
  does not measure serialization.

## Where the difference is

At saturation on plaintext, `perf stat` over the server's CPUs counted per
request:

| | roxum | axum |
|---|---:|---:|
| user-space cycles | 16,858 | 11,216 |
| kernel cycles | 17,140 | 16,032 |
| user-space instructions | 25,075 | 13,136 |
| `epoll_pwait` / `epoll_wait` calls | 0.99 | 0.03 |
| `getrandom` calls | 0.99 | 0 |

The request counts used for these ratios are approximate, so read the values to
two significant figures.

- About half of the server's cycles are in the kernel for both, mostly network
  processing. roxum also makes two system calls per request that axum avoids:
  it polls its event queue after each request, and it reads the operating
  system's random source for each request ID.
- In user space, roxum executes about twice axum's instructions per request,
  at a higher rate per cycle. A sampled cycle profile puts reading the clock
  (about 7% of user-space cycles) among the larger costs, together with HTTP
  parsing, Roc's request handling and request allocation.
- Most of the instructions those improvements removed executed
  quickly: user-space instructions fell by 20%, and user-space cycles by 7.5%.

## Build time and binary size

Measured on 2026-11-06 on the sources of roxum 0.1.0, with Roc
nightly-2026-11-04-2622062.
Each server is the small app of the throughput tests (`bench/m13/app.roc`, 63
lines; `bench/m13/axum`, 38; `bench/m13/go`, 50). Seconds are the median of three runs
([`bench/m13/compile.py`](../bench/m13/compile.py)).

- **First build**: every cache the build writes is new and empty. axum compiles its
  dependency crates and Go its standard library; downloads are not timed. roxum
  compiles the platform's Roc modules, but not its host: an app gets the host
  built, in the platform's bundle. Building the host from source, once, is the last row.
- **No change**: the same build again.
- **One line**: after changing the text one route returns.

| | Build | Linux first | No change | One line | macOS first | No change | One line |
|---|---|---:|---:|---:|---:|---:|---:|
| roxum | `--opt=dev` | 0.99 | 0.55 | 0.78 | 0.85 | 0.45 | 0.63 |
| roxum | `--opt=speed` | 4.13 | 3.60 | 3.82 | 3.34 | 2.98 | 3.13 |
| roxum | `--opt=size` | 3.74 | 3.50 | 3.74 | 2.99 | 2.65 | 2.82 |
| axum | debug | 8.54 | 0.03 | 0.65 | 9.21 | 0.06 | 0.46 |
| axum | release (LTO, one codegen unit) | 14.49 | 0.03 | 6.06 | 18.09 | 0.06 | 8.05 |
| axum | release, musl | 14.72 | 0.03 | 6.04 | — | — | — |
| Go | `go build` | 4.91 | 0.07 | 0.23 | 5.10 | 0.10 | 0.37 |
| roxum host | `zig build host` | 49.57 | 2.74 | — | 30.46 | 0.25 | — |

After a one-line change, an optimized roxum build took 0.39–0.63 times as long as
an axum release build; from nothing, 0.18–0.29 times. roxum spends about 3
seconds even when nothing changed: it repeats code generation and linking, where
Cargo and Go reuse their outputs.

Sizes in bytes, as built and after `strip`
([`bench/m13/sizes.py`](../bench/m13/sizes.py)). roxum's app is built against the
release platform, whose hosts are already stripped.

| | Build | Linux | stripped | Linking | macOS | stripped |
|---|---|---:|---:|---|---:|---:|
| roxum | `--opt=dev` | 2,222,752 | 2,014,000 | static | 1,248,240 | 1,200,104 |
| roxum | `--opt=speed` | 1,944,784 | 1,829,640 | static | 952,512 | 924,952 |
| roxum | `--opt=size` | 1,925,288 | 1,810,088 | static | 936,112 | 908,424 |
| axum | debug | 26,825,256 | 2,692,384 | glibc, dynamic | 6,188,656 | 3,331,256 |
| axum | release | 1,270,256 | 922,472 | glibc, dynamic | 1,101,792 | 867,840 |
| axum | release, musl | 1,368,816 | 987,440 | static | — | — |
| Go | `go build` | 7,217,872 | 4,864,472 | static | 7,168,114 | 6,814,376 |

On macOS all three link libSystem dynamically. A roxum app built against the
host from `zig build host`, which keeps debug information, is about 10.8 MB on
Linux before stripping.

Conditions:

- Linux: arm64 in Docker with 8 CPUs, one image per toolchain (roxum's from
  `tools/linux/test.sh`, `rust:1` with rustc 1.99.1, `golang:1.23` with Go
  1.23.12).
- macOS: Apple silicon, rustc 1.97.1 and Go 1.23.12. The load average was 2–3
  from other applications during the run.
  A first run, while a leftover process used half a CPU, was 16–64% slower
  on first builds; its medians are in `compile-macos-disturbed.txt`.
- Zig 0.16.0 for the host. Go builds with `CGO_ENABLED=0`.
- Raw results: [`bench/m13/results/`](../bench/m13/results/). The `sizes-*-release`
  files hold roxum's sizes against the release platform; the other `sizes-*`
  files, axum's and Go's, and roxum's against the development host.

## Not yet measured

- One-core and four-core budgets, and other times or hosts. These numbers come
  from one session on two cores.
- Go. It was left out of this session.
- Whether the load generator limits axum's rate. A capacity check at about
  210,000 requests/s found no limit, but axum ran faster than that here.
- Latency at fixed request rates below saturation, except for the 32 KiB echo.
- Dynamic JSON, middleware, streaming, files and database workloads.

## Reproducing

The workloads, acceptance rules and the fairness requirements are in
[the comparison protocol](../bench/m13/protocol.md). The two-host runner and
its server controller are in [remote.md](../bench/m13/remote.md), and the AWS
environment in [bench/m13/aws](../bench/m13/aws/README.md).
[The investigation guide](../bench/m13/investigation.md) explains the local
instruction counts and their limits.
