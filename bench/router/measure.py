#!/usr/bin/env python3
"""Measure first/last static sibling lookup as route count grows.

Run: python3 bench/router/measure.py OUTPUT.json
Builds outside the source tree; uses the shared HTTP measurement helper.
Counts are workload scaling classes, not input validation boundaries.
"""
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("http_bench", ROOT / "bench/m13/run.py")
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
bench.DURATION = "2s"
COUNTS = (1, 16, 128)


def main():
    oha = shutil.which("oha")
    if not oha:
        raise SystemExit("oha is required")
    subprocess.run(["zig", "build", "host"], cwd=ROOT, check=True)
    source = (ROOT / "bench/m13/app.roc").read_text()
    results = {"revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
               "duration": bench.DURATION, "runs": 5, "connections": 16, "scenarios": {}}
    with tempfile.TemporaryDirectory(prefix="roxum-router-") as directory:
        directory = pathlib.Path(directory)
        source = source.replace('"../../platform/main.roc"', json.dumps(os.path.relpath(ROOT / "platform/main.roc", directory)))
        binaries = {}
        for count in COUNTS:
            app = directory / f"routes-{count}.roc"
            app.write_text(source.replace("index == 100", f"index == {count}"))
            binary = directory / f"routes-{count}"
            subprocess.run(["roc", "build", "--opt=speed", f"--output={binary}", str(app)], cwd=ROOT, check=True)
            binaries[count] = binary
        # Rotate route-count order; compare first/last within the same binary.
        for run in range(5):
            order = COUNTS[run % len(COUNTS):] + COUNTS[:run % len(COUNTS)]
            for count in order:
                positions = [0] if count == 1 else [0, count - 1]
                if run % 2:
                    positions.reverse()
                for position in positions:
                    key = f"routes={count},position={position}"
                    row = bench.measure(oha, str(binaries[count]), "GET", f"/r{position}/items/42", 16, None)
                    if row["success_rate"] != 1 or row["errors"] or set(row["status"]) != {"200"}:
                        raise RuntimeError(row)
                    results["scenarios"].setdefault(key, []).append(row)
                    print(key, row["rps"], flush=True)
    pathlib.Path(sys.argv[1]).write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
