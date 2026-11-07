#!/usr/bin/env python3
import http.client
import os
import select
import signal
import subprocess
import sys
import time
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, ready_workers  # noqa: E402


def expect_contract_marker(server):
    readable, _, _ = select.select([server.stderr], [], [], 5)
    if not readable:
        raise RuntimeError("timed out waiting for allocator baseline marker")
    line = server.stderr.readline().strip()
    if line != "roxum-contract-request-ok":
        raise RuntimeError(f"unexpected allocator output: {line!r}")


def request(port, path, expected_status, expected_body, contract_alloc, server):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.request("GET", path, headers={"Connection": "close"})
    response = connection.getresponse()
    body = response.read()
    markers = [
        value
        for name, value in response.getheaders()
        if name.lower() == "x-middleware"
    ]
    if response.status != expected_status:
        raise RuntimeError(f"{path}: unexpected status {response.status}")
    if body != expected_body:
        raise RuntimeError(f"{path}: unexpected body {body!r}")
    if markers != ["inner", "outer"]:
        raise RuntimeError(f"{path}: unexpected layer order {markers!r}")
    connection.close()
    if contract_alloc:
        expect_contract_marker(server)


def main():
    contract_alloc = os.environ.get("ROXUM_CONTRACT_ALLOC") == "1"
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
        cases = [
            ("/pure", 200, b"inner:outer:/pure"),
            ("/stateful", 200, b"stateful"),
            ("/effectful", 200, b"effectful"),
            ("/static", 200, b"static"),
            ("/error", 418, b"error"),
        ]
        for path, status, body in cases:
            request(port, path, status, body, contract_alloc, server)
        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=6) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=6)


if __name__ == "__main__":
    main()
