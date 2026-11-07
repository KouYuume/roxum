#!/usr/bin/env python3
"""Interleave HTTP variants and a duplicate-binary noise control.

Usage: isolate.py [--connections N] OUTPUT.json name=EXE [name=EXE ...]
Use the same baseline executable twice with different names for the control.
Build every variant before running; default is five 5-second trials each.
Connections default to 1000; use --connections 64 for the plaintext scenario.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
import pathlib
import platform
import statistics
import run as bench


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--connections", type=int, default=1000)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("variants", nargs="+")
    args = parser.parse_args()
    if args.connections < 1:
        parser.error("connections must be positive")
    output = args.output
    variants = [arg.split("=", 1) for arg in args.variants]
    if any(len(pair) != 2 for pair in variants):
        parser.error("variants must be name=executable")
    if len(variants) < 2:
        raise SystemExit("at least two named executables are required")
    bench.DURATION = "5s"
    result = {"platform": platform.platform(), "duration": bench.DURATION,
              "connections": args.connections, "runs": 5,
              "date": datetime.now(timezone.utc).isoformat(),
              "executables": dict(variants), "sha256": {}, "samples": []}
    for name, exe in variants:
        result["sha256"][name] = hashlib.sha256(pathlib.Path(exe).read_bytes()).hexdigest()
    for run in range(5):
        offset = run % len(variants)
        order = variants[offset:] + variants[:offset]
        if run % 2:
            order = order[::-1]
        for name, exe in order:
            load = os.getloadavg()
            row = bench.measure("oha", exe, "GET", "/plaintext", args.connections, None)
            row.update(variant=name, run=run, load_average=load)
            result["samples"].append(row)
            output.write_text(json.dumps(result, indent=2) + "\n")
            print(name, run, row["rps"], row["success_rate"], flush=True)
    for name, _ in variants:
        rows = [r for r in result["samples"] if r["variant"] == name]
        print(name, "median", statistics.median(r["rps"] for r in rows), flush=True)


if __name__ == "__main__":
    main()
