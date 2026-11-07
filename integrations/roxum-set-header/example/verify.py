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


def request(server, port, method, path, status, body, expected_headers, allow=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.request(method, path, headers={"Connection": "close"})
    response = connection.getresponse()
    actual_body = response.read()
    if response.status != status:
        raise RuntimeError(f"{method} {path}: unexpected status {response.status}")
    if actual_body != body:
        raise RuntimeError(f"{method} {path}: unexpected body {actual_body!r}")
    response_headers = response.getheaders()
    for name, expected in expected_headers.items():
        actual = [value for field, value in response_headers if field.lower() == name.lower()]
        if actual != expected:
            raise RuntimeError(
                f"{method} {path}: unexpected {name} headers {actual!r}"
            )
    if allow is not None and response.getheader("allow") != allow:
        raise RuntimeError(f"{method} {path}: unexpected Allow {response.getheader('allow')!r}")
    connection.close()
    if os.environ.get("ROXUM_CONTRACT_ALLOC") == "1":
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
        global_headers = {"x-global": ["inner", "outer"]}
        route_headers = {"x-route": ["route"], **global_headers}
        request(server, port, "GET", "/ok", 200, b"ok", route_headers)
        request(server, port, "HEAD", "/ok", 200, b"", route_headers)
        request(server, port, "POST", "/ok", 405, b"", global_headers, "GET, HEAD")
        request(server, port, "GET", "/users/%FF", 400, b"", global_headers)
        request(server, port, "GET", "/missing", 404, b"", global_headers)
        request(server, port, "GET", "/error", 418, b"error", route_headers)
        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=6) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=6)


if __name__ == "__main__":
    main()
