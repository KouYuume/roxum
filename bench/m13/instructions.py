#!/usr/bin/env python3
"""Per-request user-space instruction counts by function and subsystem (Linux).

Usage: instructions.py [--scenario NAME] [--small N] [--large N]
                       OHA OUTPUT.json name=executable ...

Each server runs twice under callgrind: once for `--small` requests and once for
`--large`. The difference between the two runs, divided by the difference in
request count, is the cost of one request; startup, warmup and shutdown cancel.
Counts are summed over every process the server forks. Valgrind 3.19 cannot
run the Go comparison server on arm64 (it faults in runtime.osinit); that row
is recorded as invalid rather than omitted. Valgrind serializes
threads, so this measures work, not waiting, contention or kernel time, and it
is not a throughput measurement. Use it to locate costs and to check that a
change removes the work it targets; confirm throughput separately (protocol.md).

Run it in the profiling container: bench/m13/profile/run.sh. Existing output
files are never overwritten.
"""
import argparse
import collections
import glob
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run

# The first matching rule names the subsystem. Callgrind attributes inlined code
# to the source file it came from, so rules match the file before the function.
CATEGORIES = [
    ("http1 parse", r"/http1/(parser|framing|syntax|authority|request_target|request_limits|expectation|persistence)\.zig"),
    ("http1 encode", r"/http1/(encoder|response_framing|date|chunked)\.zig|writeHeader"),
    ("bridge", r"/bridge/|roc_platform_abi\.zig"),
    ("allocator", r"/allocator/|tryAlloc|roc_alloc|roc_dealloc|roc_realloc|SmpAllocator|PageAllocator|malloc|free\b|_int_free|arena\.c"),
    ("roc", r"roc__|roc_llvm|roc_builtins|dev_wrappers|roc_handle"),
    ("scheduling and locks", r"event_loop|/server\.zig|work_queue|fiber|scheduler|sync\.zig|pthread|atomic|tokio|epoll|deadline"),
    ("connection", r"/connection|request_debug|request_reader|request_id|/effect/"),
    ("memory copy", r"memcpy|memset|memmove|mem\.zig|SplitIterator|bcmp|memcmp"),
    ("hyper/axum", r"hyper|http::|axum|httparse|bytes::"),
    ("go runtime", r"\.go:|^\?\?\?:(runtime|net/http|internal/poll|syscall)\."),
]
LINE = re.compile(r"\s*([\d,]+)\s+\([^)]*\)\s+(.*)$")


def category(key):
    for name, pattern in CATEGORIES:
        if re.search(pattern, key):
            return name
    return "other"


def parse_annotation(text):
    """Self cost per `file:function`, merging callgrind's recursion suffixes."""
    costs = collections.Counter()
    totals = None
    for line in text.splitlines():
        match = LINE.match(line)
        if not match:
            continue
        count = int(match.group(1).replace(",", ""))
        name = match.group(2)
        if name.startswith("PROGRAM TOTALS"):
            totals = count
            continue
        key = re.sub(r"'\d+", "", name).split(" [", 1)[0]
        costs[key] += count
    if totals is None:
        raise ValueError("callgrind_annotate output has no PROGRAM TOTALS")
    return totals, costs


def per_request(small, large, request_delta):
    if request_delta <= 0:
        raise ValueError("the large run must send more requests than the small run")
    total = (large[0] - small[0]) / request_delta
    if total <= 0:
        raise ValueError("instruction count did not grow with the request count")
    functions = {key: (large[1].get(key, 0) - small[1].get(key, 0)) / request_delta
                 for key in set(small[1]) | set(large[1])}
    categories = collections.Counter()
    for key, value in functions.items():
        categories[category(key)] += value
    top = sorted(functions.items(), key=lambda item: item[1], reverse=True)[:60]
    return {"instructions_per_request": total,
            "categories": dict(categories.most_common()),
            "top_functions": [{"function": key, "instructions": value} for key, value in top]}


def callgrind_run(executable, oha, method, path, connections, body, requests, directory):
    """Serves `requests` requests under callgrind and returns the summed annotation."""
    out = Path(directory)
    work = out / "work"
    work.mkdir()
    log = open(out / "server.log", "w+")
    command = ["valgrind", "--tool=callgrind", f"--callgrind-out-file={out}/callgrind.%p",
               f"--log-file={out}/valgrind.%p.log", str(Path(executable).resolve())]
    server = subprocess.Popen(command, cwd=work, stdout=subprocess.PIPE, stderr=log,
                              text=True, start_new_session=True)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(server.stdout, selectors.EVENT_READ)
            if not selector.select(180):
                raise TimeoutError("server did not publish a port within 180 seconds")
        line = server.stdout.readline().strip()
        if not line:
            logs = "".join(Path(f).read_text()[-2000:] for f in glob.glob(str(out / "valgrind.*.log")))
            raise RuntimeError(f"server exited before publishing a port under valgrind:\n{logs}")
        port = int(line)
        run.validate_response(port, method, path, body)
        load = oha_count(oha, port, method, path, connections, body, requests)
    finally:
        try:
            os.killpg(server.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        server.wait(timeout=300)
        log.close()
    files = sorted(glob.glob(str(out / "callgrind.*")))
    if not files:
        raise RuntimeError("callgrind wrote no profile")
    total = 0
    costs = collections.Counter()
    for file in files:
        annotated = subprocess.run(["callgrind_annotate", "--threshold=100", "--auto=no", file],
                                   check=True, capture_output=True, text=True).stdout
        file_total, file_costs = parse_annotation(annotated)
        total += file_total
        costs.update(file_costs)
    return {"load": load, "processes": len(files)}, (total, costs)


def oha_count(oha, port, method, path, connections, body, requests):
    # One extra request validates the response; it is the same in both runs.
    command = [oha, "-n", str(requests), "-c", str(connections), "--http-version", "1.1",
               "--no-tui", "--output-format", "json", "-m", method]
    with tempfile.TemporaryDirectory(prefix="roxum-instructions-") as directory:
        if body is not None:
            body_file = Path(directory) / "body"
            body_file.write_bytes(body)
            command += ["-D", str(body_file)]
        command.append(f"http://127.0.0.1:{port}{path}")
        completed = subprocess.run(command, capture_output=True, text=True, timeout=3600)
    raw = json.loads(completed.stdout)
    status = raw.get("statusCodeDistribution") or {}
    errors = raw.get("errorDistribution") or {}
    if completed.returncode or status != {"200": requests} or any(errors.values()):
        raise RuntimeError(f"load failed: exit={completed.returncode} status={status} errors={errors}")
    return {"command": command, "status": status}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", action="append", choices=[s[0] for s in run.SCENARIOS])
    parser.add_argument("--small", type=int, default=2000)
    parser.add_argument("--large", type=int, default=12000)
    parser.add_argument("oha")
    parser.add_argument("output")
    parser.add_argument("servers", nargs="+")
    args = parser.parse_args()
    if not shutil.which("valgrind") or not shutil.which("callgrind_annotate"):
        parser.error("valgrind and callgrind_annotate are required (bench/m13/profile/run.sh)")
    output = Path(args.output)
    if output.exists():
        parser.error(f"{output} exists; results are never overwritten")
    servers = [item.split("=", 1) for item in args.servers]
    if any(len(item) != 2 for item in servers):
        parser.error("servers are name=executable")
    selected = [s for s in run.SCENARIOS if not args.scenario or s[0] in args.scenario]
    result = {"kind": "instruction-count-diagnostic", "schema": 1,
              "started_at": datetime.now(timezone.utc).isoformat(),
              "small": args.small, "large": args.large,
              "oha_sha256": hashlib.sha256(Path(shutil.which(args.oha) or args.oha).read_bytes()).hexdigest(),
              "valgrind": subprocess.run(["valgrind", "--version"], capture_output=True, text=True).stdout.strip(),
              "servers": {name: {"executable": executable, "sha256": hashlib.sha256(Path(executable).read_bytes()).hexdigest()}
                          for name, executable in servers},
              "results": []}
    for scenario, method, path, connections, body in selected:
        for name, executable in servers:
            row = {"server": name, "scenario": scenario, "connections": connections}
            try:
                with tempfile.TemporaryDirectory(prefix="roxum-callgrind-") as directory:
                    small_dir = Path(directory) / "small"
                    large_dir = Path(directory) / "large"
                    small_dir.mkdir()
                    large_dir.mkdir()
                    started = time.monotonic()
                    small_info, small = callgrind_run(executable, args.oha, method, path, connections, body, args.small, small_dir)
                    large_info, large = callgrind_run(executable, args.oha, method, path, connections, body, args.large, large_dir)
                    row.update(per_request(small, large, args.large - args.small))
                    row.update(valid=True, small_run=small_info, large_run=large_info,
                               seconds=time.monotonic() - started)
            except Exception as error:
                row.update(valid=False, exception=f"{type(error).__name__}: {error}")
            result["results"].append(row)
            summary = (f"{row['instructions_per_request']:.0f} instructions/request"
                       if row["valid"] else row["exception"])
            print(f"{scenario} {name}: {summary}", file=sys.stderr, flush=True)
    with open(output, "x") as handle:
        json.dump(result, handle, indent=1)
    print_table(result)
    return 0 if all(row["valid"] for row in result["results"]) else 1


def print_table(result):
    names = [category_name for category_name, _ in CATEGORIES] + ["other"]
    for row in result["results"]:
        if not row["valid"]:
            continue
        print(f"\n{row['scenario']} / {row['server']}: {row['instructions_per_request']:.0f} instructions/request")
        for name in names:
            value = row["categories"].get(name, 0)
            if abs(value) >= 1:
                print(f"  {value:9.0f}  {name}")


if __name__ == "__main__":
    sys.exit(main())
