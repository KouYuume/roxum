#!/usr/bin/env python3
import http.client
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "tests" / "support"))
from roxum_process import read_port, ready_workers  # noqa: E402

GENERATED_ID = re.compile(r"[0-9a-f]{32}")
CONTRACT_MARKER = "roxum-contract-request-ok"
TRACE_LINE = re.compile(
    r"\[INFO\] (?P<method>[A-Z]+) (?P<path>\S+) (?P<status>\d{3}) (?P<duration>\d+\.\d{3})ms"
    r" request_id=(?P<request_id>\S+)"
)


# The tracking host prints a marker after each request once every request
# allocation is freed and persistent allocations are back at their baseline.
# It is written after the response, so wait for it before the next request.
class ContractMarkers:
    def __init__(self, log_path):
        self.enabled = os.environ.get("ROXUM_CONTRACT_ALLOC") == "1"
        self.log_path = log_path
        self.expected = 0

    def wait_for_next(self):
        if not self.enabled:
            return
        self.expected += 1
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            with open(self.log_path) as log:
                if log.read().splitlines().count(CONTRACT_MARKER) >= self.expected:
                    return
            time.sleep(0.02)
        raise RuntimeError(f"timed out waiting for allocator baseline marker {self.expected}")


def request(markers, port, method, path, status, headers=()):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.putrequest(method, path)
    connection.putheader("Connection", "close")
    for name, value in headers:
        connection.putheader(name, value)
    connection.endheaders()
    response = connection.getresponse()
    body = response.read().decode()
    ids = [value for field, value in response.getheaders() if field.lower() == "x-request-id"]
    connection.close()
    if response.status != status:
        raise RuntimeError(f"{method} {path}: unexpected status {response.status}")
    if len(ids) != 1:
        raise RuntimeError(f"{method} {path}: expected one x-request-id, got {ids!r}")
    markers.wait_for_next()
    return ids[0], body


def expect_generated(request_id, body, received, label):
    """The handler's `request.request_id` is the generated ID the reply
    carries, and its headers hold the client's fields as received."""
    if GENERATED_ID.fullmatch(request_id) is None:
        raise RuntimeError(f"{label}: expected a generated ID, got {request_id!r}")
    if body != f"{request_id}\n{received}":
        raise RuntimeError(f"{label}: handler saw {body!r}, response has {request_id!r}")


def trace_lines(log_path):
    with open(log_path) as log:
        return [match.groupdict() for match in map(TRACE_LINE.fullmatch, log.read().splitlines()) if match]


def main():
    with tempfile.NamedTemporaryFile(prefix="roxum-trace-", suffix=".log") as log:
        server = subprocess.Popen(
            [sys.argv[1]],
            stdout=subprocess.PIPE,
            stderr=log,
            text=True,
            start_new_session=True,
        )
        try:
            port = read_port(server)
            ready_workers(server)
            markers = ContractMarkers(log.name)

            kept_id = "client-id-" + "x" * 118
            kept, kept_body = request(markers, port, "GET", "/request-id", 200, [("x-request-id", kept_id)])
            missing, missing_body = request(markers, port, "GET", "/request-id", 200)
            too_long, too_long_body = request(
                markers, port, "GET", "/request-id", 200, [("x-request-id", kept_id + "x")]
            )
            spaced, spaced_body = request(markers, port, "GET", "/request-id", 200, [("x-request-id", "a b")])
            repeated, repeated_body = request(
                markers, port, "GET", "/request-id", 200, [("x-request-id", "a"), ("x-request-id", "b")]
            )
            other = {
                (method, path, status): request(markers, port, method, path, status)[0]
                for method, path, status in [
                    ("HEAD", "/ok", 200),
                    ("POST", "/ok", 405),
                    ("GET", "/missing", 404),
                    ("GET", "/users/%FF", 400),
                    ("GET", "/error", 418),
                ]
            }

            os.killpg(server.pid, signal.SIGTERM)
            if server.wait(timeout=6) != 0:
                raise RuntimeError(f"server shutdown returned {server.returncode}")
        finally:
            if server.poll() is None:
                os.killpg(server.pid, signal.SIGKILL)
                server.wait(timeout=6)

        # The host's default (`Server.RequestIdSource.Generate`) does not trust
        # the client: even a valid ID of the maximum length is not used. Which
        # incoming IDs `TrustIncoming` keeps is checked by the host's unit tests.
        if len(kept_id) != 128 or kept == kept_id:
            raise RuntimeError(f"a client ID was kept: {kept!r}")
        for request_id, body, received, label in [
            (kept, kept_body, kept_id, "valid client ID"),
            (missing, missing_body, "", "missing"),
            (too_long, too_long_body, kept_id + "x", "too long"),
            (spaced, spaced_body, "a b", "space"),
            (repeated, repeated_body, "a,b", "repeated"),
        ]:
            expect_generated(request_id, body, received, label)
        generated = [kept, missing, too_long, spaced, repeated, *other.values()]
        for request_id in other.values():
            if GENERATED_ID.fullmatch(request_id) is None:
                raise RuntimeError(f"expected a generated ID, got {request_id!r}")
        if len(set(generated)) != len(generated):
            raise RuntimeError("generated request IDs were reused")

        lines = trace_lines(log.name)
        expected = [
            ("GET", "/request-id", "200", request_id)
            for request_id in [kept, missing, too_long, spaced, repeated]
        ] + [(method, path, str(status), request_id) for (method, path, status), request_id in other.items()]
        observed = sorted((line["method"], line["path"], line["status"], line["request_id"]) for line in lines)
        if observed != sorted(expected):
            raise RuntimeError(f"unexpected trace lines: {observed!r}")


if __name__ == "__main__":
    main()
