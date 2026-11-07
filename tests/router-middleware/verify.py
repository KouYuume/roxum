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


def request(server, port, method, path, status, body, markers, contract_alloc, allow=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.request(method, path, headers={"Connection": "close"})
    response = connection.getresponse()
    actual_body = response.read()
    actual_markers = [
        value
        for name, value in response.getheaders()
        if name.lower() == "x-middleware"
    ]
    if response.status != status:
        raise RuntimeError(f"{method} {path}: unexpected status {response.status}")
    if actual_body != body:
        raise RuntimeError(f"{method} {path}: unexpected body {actual_body!r}")
    if actual_markers != markers:
        raise RuntimeError(f"{method} {path}: unexpected layers {actual_markers!r}")
    if allow is not None and response.getheader("allow") != allow:
        raise RuntimeError(f"{method} {path}: unexpected Allow {response.getheader('allow')!r}")
    connection.close()
    if contract_alloc:
        expect_contract_marker(server)


def run_server(executable, contract_alloc, cases):
    server = subprocess.Popen(
        [executable],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        port = read_port(server)
        ready_workers(server)
        for case in cases:
            method, path, status, body, markers, *optional = case
            allow = optional[0] if optional else None
            request(
                server,
                port,
                method,
                path,
                status,
                body,
                markers,
                contract_alloc,
                allow,
            )
        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=6) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=6)


def main():
    contract_alloc = os.environ.get("ROXUM_CONTRACT_ALLOC") == "1"
    global_layers = ["router-inner", "router-outer"]
    route_layers = ["route-inner", "route-outer", *global_layers]
    run_server(
        sys.argv[1],
        contract_alloc,
        [
            ("GET", "/method/42", 200, b"route-inner:route-outer:router-inner:router-outer:/method/42", route_layers),
            ("HEAD", "/method/42", 200, b"", route_layers),
            ("POST", "/method/42", 405, b"", global_layers, "GET, HEAD"),
            ("GET", "/method/%FF", 400, b"", global_layers),
            ("GET", "/head", 200, b"get:router-inner:router-outer:/head", ["get", *global_layers]),
            ("HEAD", "/head", 200, b"", ["head", *global_layers]),
            ("GET", "/error", 418, b"error", route_layers),
            # An encoded alias of a static route runs that route's layers
            # instead of reaching the fallback.
            ("GET", "/%65rror", 418, b"error", route_layers),
            # A capture that decodes to a dot segment is rejected.
            ("GET", "/method/%2e%2e", 400, b"", global_layers),
            ("GET", "/api/nested", 200, b"nested:router-inner:router-outer:/api/nested", ["nested", *global_layers]),
            ("GET", "/merged", 200, b"merged:router-inner:router-outer:/merged", ["merged", *global_layers]),
            ("GET", "/missing", 200, b"fallback", global_layers),
        ],
    )
    run_server(
        sys.argv[2],
        contract_alloc,
        [("GET", "/missing", 404, b"", ["default"])],
    )


if __name__ == "__main__":
    main()
