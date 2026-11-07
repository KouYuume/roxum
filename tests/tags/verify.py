#!/usr/bin/env python3
"""M24 phase 3: route tags read by a layer, and values a layer provides, in one
backend and allocator."""
import http.client
import os
import pathlib
import signal
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, ready_workers  # noqa: E402

USER = {"x-user": "alice"}

# (method, path, headers, status, body or None, limit, tag count)
CASES = [
    ("GET", "/open", {}, 200, b"ok", "0", "0"),
    # Each method its own tags, and the outer tags on both.
    ("GET", "/article", USER, 200, b"alice", "100", "2"),
    ("DELETE", "/article", USER, 200, b"alice", "5", "2"),
    # A BeforeBody stage answers from a tag.
    ("GET", "/article", {}, 401, b"", "100", "2"),
    # A 405 has no method, so MethodRouter.tags are not seen.
    ("PUT", "/article", USER, 405, b"", "0", "0"),
    # provided: no stage set it.
    ("GET", "/forgot", USER, 500, None, "0", "0"),
    # optional: left out on purpose, set, and no stage ran.
    ("GET", "/page", {}, 200, b"hello guest", "0", "1"),
    ("GET", "/page", USER, 200, b"hello alice", "0", "1"),
    ("GET", "/page-forgot", {}, 500, None, "0", "0"),
    # A nested router's tags; add_tags covers its route and that route's 405.
    ("GET", "/nested/a", {}, 200, b"ok", "1", "2"),
    ("POST", "/nested/a", {}, 405, b"", "0", "1"),
    # A path no route has has no tags.
    ("GET", "/missing", {}, 404, b"", "0", "0"),
]


def main():
    contract_alloc = os.environ.get("ROXUM_CONTRACT_ALLOC") == "1"
    server = subprocess.Popen([sys.argv[1]], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        port = read_port(server)
        ready_workers(server)
        for method, path, headers, status, body, limit, tags in CASES:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            connection.request(method, path, headers={"Connection": "close", **headers})
            response = connection.getresponse()
            data = response.read()
            connection.close()
            label = f"{method} {path} {headers}"
            if response.status != status:
                raise RuntimeError(f"{label}: status {response.status}, expected {status}")
            if body is not None and data != body:
                raise RuntimeError(f"{label}: body {data!r}, expected {body!r}")
            if response.getheader("x-limit") != limit or response.getheader("x-tags") != tags:
                raise RuntimeError(f"{label}: limit {response.getheader('x-limit')}, tags {response.getheader('x-tags')}, expected {limit}, {tags}")
        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=10) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
        stderr = server.stderr.read()
        if contract_alloc and stderr.count("roxum-contract-request-ok") != len(CASES):
            raise RuntimeError(f"allocator markers for {len(CASES)} requests: {stderr!r}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=10)


if __name__ == "__main__":
    main()
