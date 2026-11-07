#!/usr/bin/env python3
"""M24 phase 3: what a layer covers, nested and merged routers, fallbacks, and
checks before routing, in one backend and allocator."""
import http.client
import os
import pathlib
import signal
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, ready_workers  # noqa: E402

ROOT = ["root"]

# (method, path, status, body or None, stages, Allow or None)
SCOPES = [
    # Above the layer, inside it; below it, not.
    ("GET", "/before", 200, b"ok", ROOT, None),
    ("GET", "/after", 200, b"ok", [], None),
    # The default 404 stands where Router.new is written.
    ("GET", "/missing", 404, b"", ROOT, None),
    # A nested child's layer: its route, the route's 405 and 400, innermost
    # first; another path under its prefix is the root's default 404.
    ("GET", "/admin/users/1", 200, b"ok", ["admin", "root"], None),
    ("POST", "/admin/users/1", 405, b"", ["admin", "root"], "GET, HEAD"),
    ("GET", "/admin/users/%FF", 400, b"", ["admin", "root"], None),
    ("GET", "/admin/other", 404, b"", ROOT, None),
    # A nested child's fallback answers under its prefix, inside its layer.
    ("GET", "/api/items/1", 200, b"ok", ["api", "root"], None),
    ("GET", "/api/other", 404, b"api not found", ["api", "root"], None),
    ("POST", "/api/items/1", 405, b"api no method", ["api", "root"], "GET, HEAD"),
    ("GET", "/api/items/%FF", 400, b"api bad path", ["api", "root"], None),
    # A prefix with a parameter.
    ("GET", "/tenants/acme/home", 200, b"ok", ROOT, None),
    ("GET", "/tenants/acme/other", 404, b"tenant not found", ROOT, None),
    # Merged: the right side's layer stays on its routes.
    ("GET", "/right", 200, b"ok", ["right", "root"], None),
    ("POST", "/right", 405, b"", ["right", "root"], "GET, HEAD"),
    # Merged on one path: each method its own layer, a 405 neither's.
    ("GET", "/shared", 200, b"ok", ["shared-get", "root"], None),
    ("DELETE", "/shared", 200, b"ok", ["shared-delete", "root"], None),
    ("PUT", "/shared", 405, b"", ROOT, "GET, HEAD, DELETE"),
    # Before routing: rewrites what is matched, or answers through no layer.
    ("GET", "/before/", 200, b"ok", ROOT, None),
    ("GET", "/blocked", 403, b"", [], None),
]

FALLBACK = [
    ("GET", "/items/1", 200, b"ok", ["second", "first"], None),
    # The root fallback is under the layer written after it only.
    ("GET", "/missing", 404, b"not found", ["second"], None),
    # A 405 runs the path's layers; the fallback's reply gets Allow.
    ("POST", "/items/1", 405, b"methods 2", ["second", "first"], "GET, HEAD"),
    # An Err from the fallback is a reply too.
    ("GET", "/items/%FF", 400, b"bad path", ["second", "first"], None),
]


def run(executable, cases, contract_alloc):
    server = subprocess.Popen([executable], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        port = read_port(server)
        ready_workers(server)
        for method, path, status, body, stages, allow in cases:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            connection.request(method, path, headers={"Connection": "close"})
            response = connection.getresponse()
            data = response.read()
            actual = [value for name, value in response.getheaders() if name.lower() == "x-stage"]
            connection.close()
            label = f"{method} {path}"
            if response.status != status:
                raise RuntimeError(f"{label}: status {response.status}, expected {status}")
            if data != body:
                raise RuntimeError(f"{label}: body {data!r}, expected {body!r}")
            if actual != stages:
                raise RuntimeError(f"{label}: stages {actual!r}, expected {stages!r}")
            if allow is not None and response.getheader("allow") != allow:
                raise RuntimeError(f"{label}: Allow {response.getheader('allow')!r}, expected {allow!r}")
        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=10) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
        stderr = server.stderr.read()
        if contract_alloc and stderr.count("roxum-contract-request-ok") != len(cases):
            raise RuntimeError(f"allocator markers for {len(cases)} requests: {stderr!r}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=10)


def main():
    contract_alloc = os.environ.get("ROXUM_CONTRACT_ALLOC") == "1"
    run(sys.argv[1], SCOPES, contract_alloc)
    run(sys.argv[2], FALLBACK, contract_alloc)


if __name__ == "__main__":
    main()
