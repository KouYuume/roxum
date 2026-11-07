#!/usr/bin/env python3
"""Compare repeated body uploads: OUTPUT.json before=EXE after=EXE.

32 KiB, 128 KiB, and 1 MiB represent medium and large body workloads,
not input validation boundaries. Measures process RSS after the workload.
"""
import importlib.util
import json
import os
import pathlib
import platform
import signal
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("http_bench", ROOT / "bench/m13/run.py")
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
bench.DURATION = "2s"


def rss(parent):
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss="], text=True)
    return sum(int(kib) for pid, ppid, kib in (row.split() for row in rows.splitlines())
               if int(pid) == parent or int(ppid) == parent)


def main():
    output = pathlib.Path(sys.argv[1])
    servers = [arg.split("=", 1) for arg in sys.argv[2:]]
    results = {"platform": platform.platform(), "load_average": os.getloadavg(),
               "duration": bench.DURATION, "runs": 5, "connections": 16, "samples": []}
    for size in (32768, 131072, 1048576):
        body = b"x" * size
        for run in range(5):
            for name, exe in (servers if run % 2 == 0 else servers[::-1]):
                server, port = bench.run_server(exe)
                try:
                    initial = rss(server.pid)
                    row = bench.run_oha("oha", port, "POST", "/echo", 16, body)
                    row.update(version=name, size=size, run=run, initial_rss_kib=initial,
                               final_rss_kib=rss(server.pid))
                    if row["success_rate"] != 1 or row["errors"] or set(row["status"]) != {"200"}:
                        raise RuntimeError(row)
                    results["samples"].append(row)
                    output.write_text(json.dumps(results, indent=2) + "\n")
                    print(name, size, row["rps"], row["final_rss_kib"], flush=True)
                finally:
                    os.killpg(server.pid, signal.SIGTERM)
                    server.wait(timeout=10)


if __name__ == "__main__":
    main()
