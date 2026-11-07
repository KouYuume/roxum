#!/usr/bin/env python3
import http.client
import os
import select
import signal
import subprocess
import sys
import time
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "tests" / "support"))
from roxum_process import read_port, ready_workers  # noqa: E402


# The tracking host prints this marker after each request once every request
# allocation is freed and persistent allocations are back at their baseline.
def expect_contract_marker(server):
    readable, _, _ = select.select([server.stderr], [], [], 5)
    if not readable:
        raise RuntimeError("timed out waiting for allocator baseline marker")
    line = server.stderr.readline().strip()
    if line != "roxum-contract-request-ok":
        raise RuntimeError(f"unexpected allocator output: {line!r}")


def request(server, port, method, target, status, body, contract_expected=True):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.request(method, target, headers={"Connection": "close"})
    response = connection.getresponse()
    actual_body = response.read()
    connection.close()
    if response.status != status:
        raise RuntimeError(f"{method} {target}: unexpected status {response.status}")
    if actual_body != body:
        raise RuntimeError(f"{method} {target}: unexpected body {actual_body!r}")
    if contract_expected and os.environ.get("ROXUM_CONTRACT_ALLOC") == "1":
        expect_contract_marker(server)


def main():
    server = subprocess.Popen(
        [sys.argv[1]],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        port = read_port(server)
        ready_workers(server)
        request(server, port, "GET", "/", 200, b"root")
        request(server, port, "GET", "/users", 200, b"/users?")
        request(server, port, "GET", "/users/", 200, b"/users?")
        request(server, port, "GET", "/users/1/", 200, b"/users/1?")
        request(server, port, "GET", "/users/?page=2", 200, b"/users?page=2")
        request(server, port, "HEAD", "/users/", 200, b"")
        # Routing sees the normalized path, so the method check and the
        # missing-route response use it too.
        request(server, port, "POST", "/users/", 405, b"")
        request(server, port, "GET", "/missing/", 404, b"")
        # The host rejects `//` before Roc runs, so no request allocation happens.
        request(server, port, "GET", "//users", 400, b"", contract_expected=False)
        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=6) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=6)


if __name__ == "__main__":
    main()
