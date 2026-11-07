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

ALLOWED = "https://app.example"
VARY = {"vary": ["Origin"]}
ACTUAL = {
    "access-control-allow-origin": [ALLOWED],
    "vary": ["Origin"],
    "access-control-allow-credentials": ["true"],
    "access-control-expose-headers": ["x-request-id"],
}
PREFLIGHT = {
    "access-control-allow-origin": [ALLOWED],
    "vary": ["Origin"],
    "access-control-allow-methods": ["GET, POST"],
    "access-control-allow-headers": ["content-type, x-token"],
    "access-control-allow-credentials": ["true"],
    "access-control-max-age": ["600"],
}
CORS_FIELDS = set(ACTUAL) | set(PREFLIGHT)


# The tracking host prints this marker after each request once every request
# allocation is freed and persistent allocations are back at their baseline.
def expect_contract_marker(server):
    readable, _, _ = select.select([server.stderr], [], [], 5)
    if not readable:
        raise RuntimeError("timed out waiting for allocator baseline marker")
    line = server.stderr.readline().strip()
    if line != "roxum-contract-request-ok":
        raise RuntimeError(f"unexpected allocator output: {line!r}")


# Checks the status, body, and every CORS-related field. Fields missing from
# `expected` must be absent.
def request(server, port, method, path, status, body, expected, headers=()):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.putrequest(method, path)
    connection.putheader("Connection", "close")
    for name, value in headers:
        connection.putheader(name, value)
    connection.endheaders()
    response = connection.getresponse()
    actual_body = response.read()
    fields = response.getheaders()
    connection.close()
    label = f"{method} {path} {list(headers)!r}"
    if response.status != status:
        raise RuntimeError(f"{label}: unexpected status {response.status}")
    if actual_body != body:
        raise RuntimeError(f"{label}: unexpected body {actual_body!r}")
    for name in CORS_FIELDS:
        actual = [value for field, value in fields if field.lower() == name]
        if actual != expected.get(name, []):
            raise RuntimeError(f"{label}: unexpected {name} {actual!r}")
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
        origin = [("Origin", ALLOWED)]
        preflight = [("Access-Control-Request-Method", "POST"), ("Access-Control-Request-Headers", "content-type")]

        # Actual requests: only an allowed single Origin gets CORS fields.
        request(server, port, "GET", "/items", 200, b"items", ACTUAL, origin)
        request(server, port, "GET", "/items", 200, b"items", VARY, [("Origin", "https://evil.example")])
        request(server, port, "GET", "/items", 200, b"items", VARY)
        request(server, port, "GET", "/items", 200, b"items", VARY, origin + origin)
        request(server, port, "POST", "/items", 200, b"created", ACTUAL, origin)

        # Compose an outer policy with grants on Ok and Err replies. Origin
        # classes are allowed, denied, and absent; bodies/status must survive.
        for path, status, body in [("/inner", 200, b"inner"), ("/error", 418, b"error")]:
            for headers, wanted in [(origin, ACTUAL), ([("Origin", "https://evil.example")], VARY), ([], VARY)]:
                request(server, port, "GET", path, status, body, wanted, headers)

        # Preflight requests are answered by the layer before routing.
        request(server, port, "OPTIONS", "/items", 204, b"", PREFLIGHT, origin + preflight)
        request(server, port, "OPTIONS", "/missing", 204, b"", PREFLIGHT, origin + preflight)
        request(server, port, "OPTIONS", "/items", 204, b"", VARY, [("Origin", "https://evil.example")] + preflight)

        # OPTIONS without Access-Control-Request-Method is an actual request.
        request(server, port, "OPTIONS", "/items", 405, b"", ACTUAL, origin)
        request(server, port, "GET", "/error", 418, b"error", ACTUAL, origin)
        request(server, port, "GET", "/missing", 404, b"", ACTUAL, origin)

        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=6) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=6)


if __name__ == "__main__":
    main()
