#!/usr/bin/env python3
"""M9b-4: request-labeled dbg / crash logs and debug mode's X-Roxum-Dbg.
M19p: a request that overflows its stack stops its worker with a line."""
import ctypes
import http.client
import os
import platform
import re
import signal
import subprocess
import sys
import tempfile
import time
import urllib.parse
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, ready_workers  # noqa: E402

MARKER = "roxum-contract-request-ok"
CONTRACT_ALLOC = os.environ.get("ROXUM_CONTRACT_ALLOC") == "1"


class Server:
    def __init__(self, executable, arguments):
        self.log = tempfile.TemporaryFile(mode="w+")
        self.process = subprocess.Popen(
            [executable, *arguments],
            stdout=subprocess.PIPE,
            stderr=self.log,
            text=True,
            start_new_session=True,
        )
        self.port = read_port(self.process)
        ready_workers(self.process)

    def get(self, path, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            connection.request("GET", path, headers=headers or {})
            response = connection.getresponse()
            return response, response.read()
        finally:
            connection.close()

    def stderr(self):
        self.log.seek(0)
        return self.log.read()

    def wait_for_log(self, pattern):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            match = re.search(pattern, self.stderr(), re.MULTILINE)
            if match:
                return match
            time.sleep(0.05)
        raise RuntimeError(f"log has no line matching {pattern!r}:\n{self.stderr()}")

    def expect_markers(self, requests):
        """The tracking allocator prints one marker per request that freed
        everything it allocated; a crashed request prints none."""
        expected = requests if CONTRACT_ALLOC else 0
        deadline = time.monotonic() + 5
        while self.stderr().splitlines().count(MARKER) < expected and time.monotonic() < deadline:
            time.sleep(0.05)
        found = self.stderr().splitlines().count(MARKER)
        if found != expected:
            raise RuntimeError(f"expected {expected} allocator markers, found {found}")

    def stop(self):
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=6)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=6)
        self.log.close()


def check_default(executable):
    server = Server(executable, [])
    try:
        response, body = server.get("/dbg?token=secret")
        if response.status != 200 or body != b"ok\n":
            raise RuntimeError(f"unexpected /dbg response {response.status} {body!r}")
        if response.headers.get_all("X-Roxum-Dbg"):
            raise RuntimeError("dbg output was attached without --debug")
        server.wait_for_log(r'^\[dbg\] pid=\d+ GET /dbg request_id=[0-9a-f]{32}: "loaded user"$')

        # A newline in a log message is escaped, so it cannot forge a line.
        response, body = server.get("/log")
        if response.status != 200:
            raise RuntimeError(f"unexpected /log response {response.status} {body!r}")
        server.wait_for_log(r"^\[INFO\] first\\x0A\[ERROR\] forged$")
        if re.search(r"^\[ERROR\] forged", server.stderr(), re.MULTILINE):
            raise RuntimeError("a log message started a line of its own")
        if "debug mode" in server.stderr():
            raise RuntimeError("debug mode warning printed without --debug")

        # A crash names its request and answers 500; the query stays out of
        # the log. Only the request stops: its worker keeps serving.
        response, body = server.get("/crash?token=secret", {"X-Request-Id": "abc123"})
        if response.status != 500 or response.headers.get("Connection") != "close":
            raise RuntimeError(f"unexpected /crash response {response.status} {response.headers} {body!r}")
        crashed = server.wait_for_log(r"^Roc crashed: pid=(\d+) GET /crash request_id=abc123: debug test crash$")
        if "secret" in server.stderr():
            raise RuntimeError("the request query reached the log")
        response, body = server.get("/dbg")
        if response.status != 200 or body != b"ok\n":
            raise RuntimeError(f"unexpected /dbg response after a crash {response.status} {body!r}")
        try:
            os.kill(int(crashed.group(1)), 0)
        except ProcessLookupError:
            raise RuntimeError("a crash stopped its worker") from None
        server.expect_markers(3)
    finally:
        server.stop()


def clear_inherited_exception_ports():
    """On macOS a crash reporter of whatever started the test may catch
    every fault of the processes under it and never end them, so an
    overflowing worker would spin instead of reaching roxum's handler. Clears
    them for this process and the server it starts."""
    if sys.platform != "darwin":
        return
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    task = ctypes.c_uint.in_dll(system, "mach_task_self_")
    bad_access_instruction_arithmetic = (1 << 1) | (1 << 2) | (1 << 3)
    exception_default = 1
    thread_state_none = 5 if platform.machine() == "arm64" else 13
    result = system.task_set_exception_ports(task, ctypes.c_uint(bad_access_instruction_arithmetic), ctypes.c_uint(0),
                                             ctypes.c_int(exception_default), ctypes.c_int(thread_state_none))
    if result != 0:
        raise RuntimeError(f"task_set_exception_ports failed with {result}")


def check_overflow(executable):
    """A request deeper than its fiber stack stops its worker with a line
    naming the request, and the other workers keep serving."""
    clear_inherited_exception_ports()
    server = Server(executable, [])
    try:
        try:
            response, body = server.get("/overflow", {"X-Request-Id": "deep1"})
        except (http.client.RemoteDisconnected, ConnectionResetError):
            pass
        else:
            raise RuntimeError(f"unexpected /overflow response {response.status} {body!r}")
        stopped = server.wait_for_log(
            r"^roxum host fatal: pid=(\d+) GET /overflow request_id=deep1: stack overflow: .+; the worker stops$")
        worker = int(stopped.group(1))
        deadline = time.monotonic() + 5
        while True:
            try:
                os.kill(worker, 0)
            except ProcessLookupError:
                break
            if time.monotonic() >= deadline:
                raise RuntimeError("an overflowing request left its worker running")
            time.sleep(0.05)
        response, body = server.get("/dbg")
        if response.status != 200 or body != b"ok\n":
            raise RuntimeError(f"unexpected /dbg response after an overflow {response.status} {body!r}")
        server.expect_markers(1)
    finally:
        server.stop()


def check_debug(executable):
    server = Server(executable, ["--debug"])
    try:
        server.wait_for_log(r"^roxum warning: debug mode")

        response, _ = server.get("/dbg")
        values = response.headers.get_all("X-Roxum-Dbg") or []
        if len(values) != 2 or values[0] != '"loaded user"':
            raise RuntimeError(f"unexpected X-Roxum-Dbg values {values!r}")
        if any(ord(character) < 0x20 or ord(character) > 0x7E for character in values[1]):
            raise RuntimeError(f"X-Roxum-Dbg is not printable ASCII: {values[1]!r}")
        if "line2 é" not in urllib.parse.unquote(values[1]):
            raise RuntimeError(f"X-Roxum-Dbg does not decode to the value: {values[1]!r}")

        # 21 values: 16 attached, the rest counted.
        response, _ = server.get("/many")
        values = response.headers.get_all("X-Roxum-Dbg") or []
        truncated = response.headers.get("X-Roxum-Dbg-Truncated")
        if len(values) != 16 or values[0] != "20" or truncated != "5":
            raise RuntimeError(f"unexpected capture limits: {len(values)} values, truncated {truncated!r}")

        # The streaming head carries the handler's value; the writer runs
        # after the head is sent, so its value is only logged.
        response, body = server.get("/stream")
        values = response.headers.get_all("X-Roxum-Dbg") or []
        if values != ['"handler"'] or body != b"chunk":
            raise RuntimeError(f"unexpected streaming response {values!r} {body!r}")
        server.wait_for_log(r'^\[dbg\] pid=\d+ GET /stream request_id=[0-9a-f]{32}: "writer"$')

        # With the head nearly full, only the fields that fit are attached;
        # the rest are counted and the response is still sent.
        response, body = server.get("/big-head")
        values = response.headers.get_all("X-Roxum-Dbg") or []
        truncated = response.headers.get("X-Roxum-Dbg-Truncated")
        if response.status != 200 or body != b"20\n":
            raise RuntimeError(f"unexpected /big-head response {response.status} {body!r}")
        if len(values) + int(truncated or "0") != 21 or len(values) >= 16 or truncated is None:
            raise RuntimeError(f"unexpected capture near the head limit: {len(values)} values, truncated {truncated!r}")
        server.expect_markers(4)
    finally:
        server.stop()


def check_unknown_argument(executable):
    result = subprocess.run([executable, "--verbose"], capture_output=True, timeout=10)
    if result.returncode != 2:
        raise RuntimeError(f"unknown argument exited with {result.returncode}")


def main():
    executable = sys.argv[1]
    check_default(executable)
    check_debug(executable)
    check_overflow(executable)
    check_unknown_argument(executable)


if __name__ == "__main__":
    main()
