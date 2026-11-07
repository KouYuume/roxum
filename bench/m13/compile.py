#!/usr/bin/env python3
"""M23d: how long the comparison servers take to compile.

    bench/m13/compile.py [--runs N] <server> <binaries dir> <output.json>

<server> is roxum, axum, axum-musl, go, or roxum-host. Each build profile
is measured in three cases, N times (default 3) each:

- clean: every cache the build writes is new and empty
- unchanged: the same build again, with nothing changed
- one line: after changing the text /plaintext returns

The server's source is copied to a new directory for each run, so the
repository's caches are not used or touched. What the build downloads is
not timed: Cargo's registry is fetched first, and roxum's host is built
beforehand (an app gets it, built, in the platform's bundle). roxum-host
times `zig build host` with new caches, for those who build the platform
from source; it has no "one line" case.

The binaries of the last run are copied to <binaries dir> for
bench/m13/sizes.py.
"""
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

BENCH = Path(__file__).resolve().parent
ROOT = BENCH.parent.parent
TEXT = "Hello, World!"
CHANGED = "Hello, World?"


def run(command, cwd, environment):
    started = time.monotonic()
    result = subprocess.run(command, cwd=cwd, env=environment, capture_output=True, text=True)
    elapsed = time.monotonic() - started
    if result.returncode != 0:
        raise SystemExit(f"{' '.join(command)} failed in {cwd}:\n{result.stdout}{result.stderr}")
    return round(elapsed, 2)


def change_line(path):
    text = path.read_text()
    if text.count(TEXT) < 1:
        raise SystemExit(f"{path} does not return {TEXT!r}")
    # Only the first: /plaintext. The json route has the same text.
    path.write_text(text.replace(TEXT, CHANGED, 1))


class Roxum:
    profiles = ["dev", "speed", "size"]

    def prepare(self, work):
        shutil.copy(BENCH / "app.roc", work / "app.roc")
        text = (work / "app.roc").read_text()
        # Roc takes a platform's path only relative to the app.
        platform_path = os.path.relpath(ROOT / "platform/main.roc", work.resolve())
        (work / "app.roc").write_text(text.replace('"../../platform/main.roc"', f'"{platform_path}"'))
        return work / "app.roc"

    def environment(self, work):
        return {**os.environ, "ROC_CACHE_DIR": str(work / "roc-cache"), "XDG_CACHE_HOME": str(work / "xdg-cache")}

    def build(self, work, profile, environment):
        return run(["roc", "build", f"--opt={profile}", "--output=server", "app.roc"], work, environment), work / "server"

    def version(self):
        return subprocess.run(["roc", "version"], capture_output=True, text=True).stdout.strip()


class Axum:
    profiles = ["debug", "release"]
    target = None

    def prepare(self, work):
        shutil.copytree(BENCH / "axum", work / "axum", ignore=shutil.ignore_patterns("target"))
        return work / "axum/src/main.rs"

    def environment(self, work):
        return {**os.environ, "CARGO_TARGET_DIR": str(work / "target")}

    def build(self, work, profile, environment):
        command = ["cargo", "build", "--quiet", "--locked"]
        if profile == "release":
            command.append("--release")
        if self.target:
            command += ["--target", self.target]
        directory = work / "target" / (self.target or "") / profile
        return run(command, work / "axum", environment), directory / "roxum-bench-axum"

    def fetch(self):
        subprocess.run(["cargo", "fetch", "--locked"], cwd=BENCH / "axum", check=True)

    def version(self):
        return subprocess.run(["rustc", "--version"], capture_output=True, text=True).stdout.strip()


class AxumMusl(Axum):
    """axum linked statically, as roxum and Go are on Linux."""
    profiles = ["release"]
    target = f"{platform.machine().replace('arm64', 'aarch64')}-unknown-linux-musl"


class Go:
    profiles = ["default"]

    def prepare(self, work):
        shutil.copytree(BENCH / "go", work / "go")
        return work / "go/main.go"

    def environment(self, work):
        return {**os.environ, "GOCACHE": str(work / "go-cache"), "GOTOOLCHAIN": "local", "CGO_ENABLED": "0"}

    def build(self, work, profile, environment):
        return run(["go", "build", "-o", "../server", "."], work / "go", environment), work / "server"

    def version(self):
        return subprocess.run(["go", "version"], capture_output=True, text=True).stdout.strip()


class RoxumHost:
    profiles = ["host"]

    def prepare(self, work):
        return None

    def environment(self, work):
        return dict(os.environ)

    def build(self, work, profile, environment):
        command = ["zig", "build", "host", "--cache-dir", str(work / "zig-cache"), "--global-cache-dir", str(work / "zig-global")]
        return run(command, ROOT, environment), None

    def version(self):
        return "zig " + subprocess.run(["zig", "version"], capture_output=True, text=True).stdout.strip()


SERVERS = {"roxum": Roxum, "axum": Axum, "axum-musl": AxumMusl, "go": Go, "roxum-host": RoxumHost}


def main():
    arguments = sys.argv[1:]
    run_count = 3
    if arguments and arguments[0] == "--runs":
        run_count = int(arguments[1])
        arguments = arguments[2:]
    if len(arguments) != 3 or arguments[0] not in SERVERS:
        raise SystemExit(__doc__)
    name, binaries, output = arguments[0], Path(arguments[1]), Path(arguments[2])
    server = SERVERS[name]()
    if hasattr(server, "fetch"):
        server.fetch()
    binaries.mkdir(parents=True, exist_ok=True)

    results = {"date": datetime.now(timezone.utc).isoformat(), "machine": platform.platform(), "cpus": os.cpu_count(),
               "server": name, "version": server.version(), "runs": run_count, "profiles": {}}
    for profile in server.profiles:
        times = {"clean": [], "unchanged": [], "one_line": []}
        for _ in range(run_count):
            with tempfile.TemporaryDirectory() as directory:
                work = Path(directory)
                source = server.prepare(work)
                environment = server.environment(work)
                seconds, binary = server.build(work, profile, environment)
                times["clean"].append(seconds)
                times["unchanged"].append(server.build(work, profile, environment)[0])
                if source is not None:
                    change_line(source)
                    times["one_line"].append(server.build(work, profile, environment)[0])
                if binary is not None:
                    shutil.copy(binary, binaries / f"{name}-{profile}")
        summary = {case: {"median_s": statistics.median(values), "runs_s": values} for case, values in times.items() if values}
        results["profiles"][profile] = summary
        print(f"{name:10} {profile:8} " + "  ".join(f"{case} {value['median_s']:>6.2f}s" for case, value in summary.items()),
              flush=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
