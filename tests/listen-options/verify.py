#!/usr/bin/env python3
"""Server.ListenOptions: the thread and process counts and the drain timeout.

The app reads `threads`, `processes`, and `drain_timeout_milliseconds` from
config/local.toml. The supervisor runs as many processes as the first asked
for (one when left out); a restarted process that asks for another number
is warned about and the count stays. Threads outside 1 to 256, processes
outside 1 to 64, and drain timeouts outside 1 ms to one hour stop the
startup.
"""
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, ready_workers, stop  # noqa: E402


def get(port):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=10) as response:
        return response.read().decode().strip()


def start(executable, directory, output):
    return subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE, stderr=output, text=True,
                            start_new_session=True)


def serves_with(executable, directory, local, local_text, expected):
    local.write_text(local_text)
    with tempfile.TemporaryFile() as output:
        server = start(executable, directory, output)
        try:
            port = read_port(server)
            workers = ready_workers(server)
            if len(workers) != expected:
                raise RuntimeError(f"{local_text!r}: expected {expected} processes, found {len(workers)}")
            if get(port) != "ok":
                raise RuntimeError("unexpected response")
        finally:
            stop(server)


def refused(executable, directory, local, local_text, message):
    local.write_text(local_text)
    result = subprocess.run([executable], cwd=directory, capture_output=True, text=True, timeout=30)
    if result.returncode == 0 or result.stdout.strip():
        raise RuntimeError(f"{local_text!r}: the server started (status {result.returncode})")
    if message not in result.stderr:
        raise RuntimeError(f"{local_text!r}: expected {message!r} in {result.stderr!r}")


def restart_keeps_count(executable, directory, local):
    """Kills a process after the override changes; the restarted process asks
    for another count, which is warned about, and the count stays."""
    local.write_text("processes = 3\n")
    with tempfile.TemporaryFile() as output:
        server = start(executable, directory, output)
        try:
            port = read_port(server)
            workers = ready_workers(server)
            if len(workers) != 3:
                raise RuntimeError(f"expected 3 processes before the restart, found {len(workers)}")
            local.write_text("processes = 2\n")
            os.kill(workers[-1], signal.SIGKILL)
            deadline = time.monotonic() + 15
            warned = False
            while time.monotonic() < deadline:
                output.seek(0)
                log = output.read().decode(errors="replace")
                current = ready_workers(server)
                if "a restarted process asked for 2 processes; keeping 3" in log and len(current) == 3 and workers[-1] not in current:
                    warned = True
                    break
                time.sleep(0.1)
            if not warned:
                raise RuntimeError(f"no warning or a changed worker count after the restart:\n{log}")
            if get(port) != "ok":
                raise RuntimeError("unexpected response after the restart")
        finally:
            stop(server)


def supervisor_killed(executable, directory, local):
    """Several processes, one of them restarted, so one that forked after the
    others: all of them end when the supervisor is killed. If a worker held the
    supervisor's end of the pipe, the others would stay."""
    local.write_text("processes = 3\n")
    with tempfile.TemporaryFile() as output:
        server = start(executable, directory, output)
        try:
            read_port(server)
            workers = ready_workers(server)
            os.kill(workers[-1], signal.SIGKILL)
            deadline = time.monotonic() + 15
            current = workers
            while time.monotonic() < deadline and (len(current) != 3 or workers[-1] in current):
                time.sleep(0.1)
                current = ready_workers(server)
            if len(current) != 3 or workers[-1] in current:
                raise RuntimeError(f"the process was not restarted: {current}")
            os.kill(server.pid, signal.SIGKILL)
            server.wait(timeout=5)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and any(running(pid) for pid in current):
                time.sleep(0.1)
            left = [pid for pid in current if running(pid)]
            if left:
                raise RuntimeError(f"processes outlived the supervisor: {left}")
        finally:
            try:
                os.killpg(server.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def running(pid):
    """A zombie does not count: a container's PID 1 may not reap."""
    state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return state != "" and not state.startswith("Z")


def main(executable):
    with tempfile.TemporaryDirectory() as directory:
        config = pathlib.Path(directory) / "config"
        config.mkdir()
        local = config / "local.toml"

        supervisor_killed(executable, directory, local)
        serves_with(executable, directory, local, "", 1)
        serves_with(executable, directory, local, "threads = 1\n", 1)
        serves_with(executable, directory, local, "threads = 2\n", 1)
        serves_with(executable, directory, local, "threads = 4\n", 1)
        serves_with(executable, directory, local, "threads = 255\n", 1)
        serves_with(executable, directory, local, "threads = 256\n", 1)
        serves_with(executable, directory, local, "processes = 3\n", 3)
        serves_with(executable, directory, local, "processes = 2\nthreads = 2\n", 2)
        serves_with(executable, directory, local, "processes = 3\ndrain_timeout_milliseconds = 20000\n", 3)
        serves_with(executable, directory, local, "threads = 1\ndrain_timeout_milliseconds = 1\n", 1)

        refused(executable, directory, local, "threads = 0\n", "Server.Threads.Fixed takes 1 to 256 threads")
        refused(executable, directory, local, "threads = 257\n", "Server.Threads.Fixed takes 1 to 256 threads")
        refused(executable, directory, local, "processes = 0\n", "Server.ListenOptions.processes takes 1 to 64")
        refused(executable, directory, local, "processes = 65\n", "Server.ListenOptions.processes takes 1 to 64")
        refused(executable, directory, local, "drain_timeout_milliseconds = 0\n",
                "drain_timeout_milliseconds takes 1 to 3600000")
        refused(executable, directory, local, "drain_timeout_milliseconds = 3600001\n",
                "drain_timeout_milliseconds takes 1 to 3600000")

        restart_keeps_count(executable, directory, local)


if __name__ == "__main__":
    main(sys.argv[1])
