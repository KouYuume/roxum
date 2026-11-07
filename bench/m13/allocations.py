#!/usr/bin/env python3
"""Count Roc allocations without changing the source tree or timing instrumented code.

Usage: python3 bench/m13/allocations.py SOURCE_ROOT OUTPUT.json [--echo]

Builds an isolated tracking host and the comparison app with 0, 1, and 100 unused
item routes. Each executable serves three identical plaintext (or --echo) requests on
one connection. The counts distinguish per-request router materialization
from startup work; these are scaling classes, not HTTP input boundaries.
Also measures three streaming responses to verify detached-heap accounting.
"""
import http.client
import json
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import os


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout.strip()


def measure(executable, echo, stream=False):
    with tempfile.TemporaryFile(mode="w+") as log:
        server = subprocess.Popen([str(executable)], stdout=subprocess.PIPE, stderr=log,
                                  text=True, start_new_session=True)
        try:
            port = int(server.stdout.readline())
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            try:
                for _ in range(3):
                    expected = b"s" * 1_000_000 if stream else b"x" * 32768 if echo else b"Hello, World!"
                    if echo:
                        connection.request("POST", "/echo", body=expected)
                    else:
                        connection.request("GET", "/small" if stream else "/plaintext")
                    response = connection.getresponse()
                    body = response.read()
                    if response.status != 200 or body != expected:
                        raise RuntimeError(f"Unexpected response: {response.status}, {body!r}")
            finally:
                connection.close()
            # The socket write can finish before the worker checks and logs
            # request cleanup. Wait for that check before terminating it.
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if os.pread(log.fileno(), 1 << 20, 0).count(b"allocations ") == 3:
                    break
                if server.poll() is not None:
                    break
                time.sleep(0.01)
        finally:
            os.killpg(server.pid, signal.SIGTERM)
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(server.pid, signal.SIGKILL)
                server.wait()
        log.seek(0)
        lines = log.read().splitlines()
        counts = [json.loads(line.removeprefix("allocations "))
                  for line in lines if line.startswith("allocations ")]
        if server.returncode != 0 or len(counts) != 3:
            raise RuntimeError(f"Tracking failed ({server.returncode}): {lines}")
        if any(row["request_allocations"] != row["request_frees"] for row in counts):
            raise RuntimeError(f"Unbalanced request counts: {counts}")
        return counts


def main():
    source = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    echo = len(sys.argv) == 4 and sys.argv[3] == "--echo"
    target = run(str(source / "tools/roc-target.sh"))
    zig_target = run(str(source / "tools/roc-target.sh"), "--zig", target)
    result = {"machine": platform.platform(), "roc": run("roc", "--version"),
              "zig": run("zig", "version"), "target": target,
              "scenario": "echo-32KiB" if echo else "plaintext", "unused_routes": {}}
    with tempfile.TemporaryDirectory(prefix="roxum-allocations-") as directory:
        stage = Path(directory)
        shutil.copytree(source / "platform", stage / "platform", ignore=shutil.ignore_patterns("targets"))
        shutil.copytree(source / "tests/support", stage / "tests/support")
        shutil.copytree(source / "libraries", stage / "libraries")
        app_dir = stage / "bench/m13"
        app_dir.mkdir(parents=True)
        target_dir = stage / "platform/targets" / target
        target_dir.mkdir(parents=True)

        # The tracking environment calls this hook with the allocator of the
        # completed request, including detached heaps. Keep all lifecycle checks.
        tracking_main = stage / "tests/support/tracking_main.zig"
        with tracking_main.open("a") as instrumented:
            instrumented.write(r'''

pub fn recordAllocations(tracker: *@import("tracking_allocator").TrackingAllocator, persistent_live: usize) void {
    @import("std").debug.print("allocations {{\"request_allocations\":{d},\"request_frees\":{d},\"requested_bytes\":{d},\"persistent_live\":{d}}}\n", .{ tracker.allocation_count, tracker.deallocation_count, tracker.requested_bytes, persistent_live });
    tracker.allocation_count = 0;
    tracker.deallocation_count = 0;
    tracker.requested_bytes = 0;
}
''')
        obj = target_dir / "host.o"
        flags = ["-fPIC", "-fcompiler-rt"] if target.endswith("musl") else []
        # Zig 0.16 crashes building for x86_64-linux-musl in ReleaseSafe with
        # the stack protector on; build.zig turns it off for the same reason.
        if target == "x64musl":
            flags.append("-fno-stack-protector")
        run("zig", "build-obj", "-target", zig_target, "-O", "ReleaseSafe", "-lc", *flags,
            f"-femit-bin={obj}", "--dep", "host", "--dep", "tracking_allocator",
            "-Mroot=tests/support/tracking_main.zig", "-Mhost=platform/host/host.zig",
            "-Mtracking_allocator=tests/support/allocator/tracking_allocator.zig", cwd=stage)
        run("zig", "ar", "rcs", str(target_dir / "libhost.a"), str(obj))
        run(str(source / "tools/musl-runtime.sh"), target, str(target_dir))
        original = (source / "bench/m13/app.roc").read_text()
        assert original.count("index == 100") == 1
        for count in (0, 1, 100):
            app = app_dir / "app.roc"
            app.write_text(original.replace("index == 100", f"index == {count}"))
            executable = stage / f"server-{count}"
            run("roc", "build", "--opt=speed", f"--target={target}",
                f"--output={executable}", str(app))
            counts = measure(executable, echo)
            result["unused_routes"][str(count)] = counts
            print(f"{count} unused routes: {counts}", flush=True)
        # Exercise the same hook after ownership moves to a detached heap.
        stream_app = stage / "bench/stream/app.roc"
        stream_app.parent.mkdir(parents=True)
        shutil.copyfile(source / "bench/stream/app.roc", stream_app)
        stream_executable = stage / "stream"
        run("roc", "build", "--opt=speed", f"--target={target}",
            f"--output={stream_executable}", str(stream_app))
        result["detached_stream"] = measure(stream_executable, False, stream=True)
        print(f"detached stream: {result['detached_stream']}", flush=True)
    output.write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
