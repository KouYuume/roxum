#!/usr/bin/env python3
"""examples/middleware: what each tag makes the layers do, in one backend and
allocator. A fresh process starts with no posts counted."""
import http.client
import json
import os
import pathlib
import signal
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, ready_workers  # noqa: E402

ALICE = {"Authorization": "Bearer alice-token"}
ADMIN = {"Authorization": "Bearer admin-token"}
JSON = {"Content-Type": "application/json"}
SHARED = [{"author": "alice", "id": 1, "shared": True, "text": "Shared with everyone"}]
MINE = SHARED + [{"author": "alice", "id": 2, "shared": False, "text": "Only for alice"}]
NO_STORE = "private, no-store"

# (method, path, headers, body, status, expected body, cache-control)
CASES = [
    # No tag: no layer acts, and the reply is not marked private.
    ("GET", "/notes", {}, None, 200, SHARED, None),
    # MembersOnly: no token, a token nobody has, another scheme, and a member.
    ("GET", "/notes/mine", {}, None, 401, b"sign in first\n", NO_STORE),
    ("GET", "/notes/mine", {"Authorization": "Bearer nobody"}, None, 401, b"sign in first\n", NO_STORE),
    ("GET", "/notes/mine", {"Authorization": "Basic YWxpY2U6eA=="}, None, 401, b"sign in first\n", NO_STORE),
    ("GET", "/notes/mine", ALICE, None, 200, MINE, NO_STORE),
    # AdminOnly: a member is refused; an admin deletes a note that exists, not one that does not.
    ("DELETE", "/notes/1", ALICE, None, 403, b"admins only\n", NO_STORE),
    ("DELETE", "/notes/1", {}, None, 401, b"sign in first\n", NO_STORE),
    ("DELETE", "/notes/1", ADMIN, None, 204, b"", NO_STORE),
    ("DELETE", "/notes/9", ADMIN, None, 404, b"", NO_STORE),
    # A path that does not match the route's parameter type.
    ("DELETE", "/notes/first", ADMIN, None, 400, None, NO_STORE),
    # A 405 has no method, so it has no method's tags.
    ("GET", "/notes/1", {}, None, 405, b"", None),
    # MembersOnly and Limit(5): refused before the body, then five posts per user.
    ("POST", "/notes", JSON, b'{"text":"hi"}', 401, b"sign in first\n", NO_STORE),
    ("POST", "/notes", {**ALICE, **JSON}, b'{"text":"one"}', 201, {"author": "alice", "text": "one"}, NO_STORE),
    # The limit counts the request before its body is read, so a bad body counts too.
    ("POST", "/notes", {**ALICE, **JSON}, b'{"text":', 400, None, NO_STORE),
    ("POST", "/notes", {**ALICE, **JSON}, b'{"text":"three"}', 201, {"author": "alice", "text": "three"}, NO_STORE),
    ("POST", "/notes", {**ALICE, **JSON}, b'{"text":"four"}', 201, {"author": "alice", "text": "four"}, NO_STORE),
    ("POST", "/notes", {**ALICE, **JSON}, b'{"text":"five"}', 201, {"author": "alice", "text": "five"}, NO_STORE),
    ("POST", "/notes", {**ALICE, **JSON}, b'{"text":"six"}', 429, None, NO_STORE),
    # Another user has a count of their own.
    ("POST", "/notes", {**ADMIN, **JSON}, b'{"text":"admin"}', 201, {"author": "admin", "text": "admin"}, NO_STORE),
]


def request(port, method, path, headers, body):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    connection.request(method, path, body=body, headers={"Connection": "close", **headers})
    response = connection.getresponse()
    data = response.read()
    connection.close()
    return response, data


def main():
    server = subprocess.Popen([sys.argv[1]], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        port = read_port(server)
        ready_workers(server)
        for method, path, headers, body, status, expected, cache in CASES:
            response, data = request(port, method, path, headers, body)
            label = f"{method} {path} {headers}"
            if response.status != status:
                raise RuntimeError(f"{label}: status {response.status}, expected {status}: {data!r}")
            if isinstance(expected, bytes) and data != expected:
                raise RuntimeError(f"{label}: body {data!r}, expected {expected!r}")
            if isinstance(expected, (list, dict)) and json.loads(data) != expected:
                raise RuntimeError(f"{label}: body {data!r}, expected {expected!r}")
            if response.getheader("cache-control") != cache:
                raise RuntimeError(f"{label}: cache-control {response.getheader('cache-control')!r}, expected {cache!r}")
            if status == 401 and response.getheader("www-authenticate") != "Bearer":
                raise RuntimeError(f"{label}: www-authenticate {response.getheader('www-authenticate')!r}")
        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=10) != 0:
            raise RuntimeError(f"server exited with {server.returncode}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait()
    print("PASS — examples/middleware")


if __name__ == "__main__":
    main()
