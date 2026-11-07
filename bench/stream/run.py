#!/usr/bin/env python3
"""Measures streaming responses: time until the last byte for N clients at once.

    bench/stream/run.py [--runs N] <oha> <executable> [<executable> ...]

Each route and client count is measured N times (default 5) per executable,
rotating the executables between runs; the median is reported. oha reads as
fast as it can and runs on the same machine, so compare executables within one
run.
"""
import json
import statistics
import subprocess
import sys
import time
import os
import signal

CASES = [
    # route, body bytes per response, clients
    ("/small", 10_000 * 100, 1),
    ("/small", 10_000 * 100, 64),
    ("/large", 256 * 64 * 1024, 1),
    ("/large", 256 * 64 * 1024, 64),
]
REQUESTS_PER_CLIENT = 4


def measure(oha, port, path, body_bytes, clients):
    """Seconds per response with `clients` connections each fetching
    `REQUESTS_PER_CLIENT` responses."""
    requests = clients * REQUESTS_PER_CLIENT
    command = [oha, "-n", str(requests), "-c", str(clients), "--no-tui", "--output-format", "json",
               f"http://127.0.0.1:{port}{path}"]
    result = json.loads(subprocess.run(command, check=True, capture_output=True, text=True).stdout)
    summary = result["summary"]
    if summary["successRate"] != 1 or summary.get("sizePerRequest", body_bytes) < body_bytes:
        raise RuntimeError(f"{path}: {summary}")
    return summary["total"] / REQUESTS_PER_CLIENT


def main():
    arguments = sys.argv[1:]
    runs = 5
    if arguments[:1] == ["--runs"]:
        runs = int(arguments[1])
        arguments = arguments[2:]
    oha, executables = arguments[0], arguments[1:]
    samples = {(executable, case): [] for executable in executables for case in CASES}
    for run in range(runs):
        order = executables[run % len(executables):] + executables[:run % len(executables)]
        for executable in order:
            server = subprocess.Popen([executable], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, start_new_session=True)
            try:
                port = int(server.stdout.readline().strip())
                time.sleep(1)
                for case in CASES:
                    samples[(executable, case)].append(measure(oha, port, *case))
            finally:
                os.killpg(server.pid, signal.SIGTERM)
                server.wait(timeout=10)
    for case in CASES:
        path, body_bytes, clients = case
        line = f"{path:7} clients={clients:3}"
        for executable in executables:
            median = statistics.median(samples[(executable, case)])
            megabytes = body_bytes * clients / median / 1e6
            line += f" | {os.path.basename(os.path.dirname(executable)) or executable}: {median * 1000:8.1f} ms {megabytes:8.1f} MB/s"
        print(line)


if __name__ == "__main__":
    main()
