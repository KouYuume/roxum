#!/usr/bin/env python3
"""Echo load with worker RSS samples; this is not an RPS benchmark.

Usage: python3 bench/m13/memory.py OHA SERVER OUTPUT.json [SECONDS]
Samples the supervisor's direct children. Retains oha errors and server stderr.
"""
import hashlib
import json
import os
import platform
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import time


def workers_rss(parent):
    workers = []
    if sys.platform == "darwin":
        rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss="], text=True)
        for row in rows.splitlines():
            pid, ppid, rss = map(int, row.split())
            if ppid == parent:
                workers.append({"pid": pid, "rss_kib": rss})
        return workers
    children = Path(f"/proc/{parent}/task/{parent}/children").read_text().split()
    for child in children:
        try:
            status = Path(f"/proc/{child}/status").read_text().splitlines()
            rss = next(int(line.split()[1]) for line in status if line.startswith("VmRSS:"))
            workers.append({"pid": int(child), "rss_kib": rss})
        except (FileNotFoundError, ProcessLookupError, StopIteration):
            continue  # Exit/restart can race a sample; retain the PID sequence.
    return workers


def measure(oha, executable, seconds):
    samples = []
    with tempfile.TemporaryDirectory(prefix="roxum-memory-") as directory:
        body = Path(directory) / "body"
        body.write_bytes(b"x" * 32768)
        with tempfile.TemporaryFile(mode="w+") as log, tempfile.TemporaryFile(mode="w+") as output:
            server = subprocess.Popen([executable], stdout=subprocess.PIPE, stderr=log,
                                      text=True, start_new_session=True)
            load = None
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(server.stdout, selectors.EVENT_READ)
                    if not selector.select(20):
                        raise TimeoutError("Server did not publish a port")
                port = int(server.stdout.readline())
                start = time.monotonic()
                load = subprocess.Popen([oha, "-z", f"{seconds}s", "-c", "64", "--no-tui",
                                         "--output-format", "json", "-m", "POST", "-D", str(body),
                                         f"http://127.0.0.1:{port}/echo"], stdout=output)
                while load.poll() is None:
                    workers = workers_rss(server.pid)
                    samples.append({"seconds": time.monotonic() - start, "workers": workers,
                                    "total_rss_kib": sum(worker["rss_kib"] for worker in workers)})
                    time.sleep(1)
                output.seek(0)
                result = {"oha_exit_code": load.returncode, "oha": json.load(output), "samples": samples}
            finally:
                if load is not None and load.poll() is None:
                    load.terminate()
                    load.wait(timeout=10)
                if server.poll() is None:
                    os.killpg(server.pid, signal.SIGTERM)
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(server.pid, signal.SIGKILL)
                    server.wait()
            log.seek(0)
            result["server_stderr"] = log.read()
    result.update(server=executable, machine=platform.platform(), sha256=hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
                  duration_seconds=seconds, scenario="POST /echo, 32768 bytes, 64 connections")
    return result


if __name__ == "__main__":
    if not (sys.platform.startswith("linux") or sys.platform == "darwin"):
        raise SystemExit("RSS sampling supports Linux and macOS")
    oha, executable, destination = sys.argv[1:4]
    seconds = int(sys.argv[4]) if len(sys.argv) > 4 else 10
    if seconds <= 0:
        raise SystemExit("SECONDS must be positive")
    Path(destination).write_text(json.dumps(measure(oha, executable, seconds), indent=2) + "\n")
