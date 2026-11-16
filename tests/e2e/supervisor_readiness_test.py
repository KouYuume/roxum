#!/usr/bin/env python3
"""Exercise startup timeout, restart timeout and shutdown during readiness."""
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import time
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import children, read_port  # noqa: E402


def start(binary, **environment):
    return subprocess.Popen([binary], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            start_new_session=True, env={**os.environ, **environment})


def cleanup(server):
    try:
        os.killpg(server.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    server.wait(timeout=3)


def main():
    with tempfile.TemporaryDirectory(prefix="roxum-readiness-") as directory:
        binary = str(Path(directory) / "fixture")
        # The build passes its own Zig so the fixture matches the host build.
        zig = sys.argv[1] if len(sys.argv) > 1 else "zig"
        subprocess.run([zig, "build-exe", "-lc", "--dep", "host",
                        "-Mroot=tests/e2e/supervisor_fixture.zig",
                        "-Mhost=platform/host/host.zig", "-femit-bin=" + binary], check=True)
        server = start(binary, ROXUM_TEST_STARTUP_STALL="1")
        try:
            assert server.wait(timeout=3) != 0
            assert server.stdout.read() == b"", "port published before every worker was ready"
        finally:
            cleanup(server)

        check_restarts(binary, directory, shutdown=False)
        check_restarts(binary, directory, shutdown=True)


def check_restarts(binary, directory, *, shutdown):
    case = "shutdown" if shutdown else "timeout"
    marker = str(Path(directory) / f"{case}-stall")
    start_log = Path(directory) / f"{case}-starts"
    # Keep the 200 ms retry test separate from clean shutdown: a worker killed
    # by that deadline can legitimately make a concurrent shutdown exit 1.
    environment = {"ROXUM_TEST_WAIT_FOR_SHUTDOWN": "1"} if shutdown else {}
    server = start(binary, ROXUM_TEST_STALL_FILE=marker,
                   ROXUM_TEST_START_LOG=str(start_log), **environment)
    try:
        assert select.select([server.stdout], [], [], 3)[0], "no initial readiness"
        if read_port(server) <= 0:
            raise RuntimeError("the published port is not positive")
        initial = children(server.pid)
        assert len(initial) == 2
        Path(marker).touch()
        os.kill(initial[0], signal.SIGKILL)
        healthy = initial[1]
        seen = set()
        wanted = 1 if shutdown else 3
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            assert server.poll() is None, "restart timeout stopped supervisor"
            os.kill(healthy, 0)
            # The fixture logs after checking the stall marker. In the shutdown
            # case its readiness deadline cannot kill it before our signal.
            seen = {int(line) for line in start_log.read_text().split()} - set(initial)
            if len(seen) >= wanted:
                break
            time.sleep(0.02)
        assert len(seen) >= wanted, f"expected {wanted} starts, observed {len(seen)}"
        if shutdown:
            # The replacement proves the original killed worker was reaped.
            # Signal only the supervisor; both ready and starting workers must
            # be drained and reaped by it, rather than by test cleanup.
            os.kill(server.pid, signal.SIGTERM)
            code = server.wait(timeout=2)
            assert code == 0, f"shutdown during readiness exited {code}"
            for pid in [healthy, *seen]:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    continue
                raise AssertionError(f"worker {pid} survived shutdown")
    finally:
        cleanup(server)


if __name__ == "__main__":
    main()
