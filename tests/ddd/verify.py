#!/usr/bin/env python3
"""Exercise the users API through its use cases and PostgreSQL adapters."""
import concurrent.futures
import http.client
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile
import time
import urllib.parse
import uuid

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, ready_workers

MARKER = "roxum-contract-request-ok"


def main(executable, database_port, password_file, contract_alloc):
    with tempfile.TemporaryDirectory() as directory:
        config = pathlib.Path(directory) / "config"
        config.mkdir()
        (config / "local.toml").write_text(
            f'[database]\nport = {database_port}\npassword_file = "{password_file}"\n')
        log = tempfile.TemporaryFile(mode="w+")
        server = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE,
                                  stderr=log, text=True, start_new_session=True)
        requests = []
        try:
            port = read_port(server)
            ready_workers(server)

            def request(method, route, expected, value=None, raw=None, content_type="application/json"):
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
                body = raw if raw is not None else (json.dumps(value) if value is not None else None)
                try:
                    connection.request(method, route, body=body,
                                       headers={"Content-Type": content_type} if body is not None and content_type else {})
                    response = connection.getresponse()
                    data = response.read()
                    requests.append((method, route))
                    assert response.status == expected, (method, route, expected, response.status, data)
                    if expected == 200:
                        assert response.getheader("Content-Type").startswith("application/json")
                        return json.loads(data)
                    return data
                finally:
                    connection.close()

            def create(name, email):
                before = int(time.time() * 1000)
                user = request("POST", "/users", 200, {"name": name, "email": email})
                assert set(user) == {"id", "name", "email"}
                assert user["name"] == name and user["email"] == email
                identifier = uuid.UUID(user["id"])
                assert identifier.version == 7 and identifier.variant == uuid.RFC_4122
                assert before <= identifier.int >> 80 <= int(time.time() * 1000)
                assert request("GET", "/users/" + user["id"], 200) == user
                return user

            def search(**query):
                return request("GET", "/users?" + urllib.parse.urlencode(query), 200)

            alice = create("Alice", "alice@example.com")
            second = create("Alice", "other@example.com")
            assert search(email="alice@example.com") == [alice]
            assert {u["id"] for u in search(name="Alice")} == {alice["id"], second["id"]}
            assert search(name="Alice", email="alice@example.com") == [alice]
            assert search(name="Other", email="alice@example.com") == []
            assert search(name="' OR 1=1 --") == []  # Parameter binding, not SQL interpolation.
            request("GET", "/users", 400)  # No filters differs from an explicit empty filter.
            empty = create("", "empty@example.com")
            assert search(name="") == [empty]
            request("GET", "/users/00000000-0000-7000-8000-000000000000", 404)
            request("GET", "/users/not-a-uuid", 500)

            # The email contract accepts at most 254 bytes: below, at, and above.
            for length in (253, 254):
                create("Length", "a" * (length - 4) + "@b.c")
            request("POST", "/users", 400, {"name": "Length", "email": "a" * 251 + "@b.c"})
            # Distinct format rejection classes: absent separator, empty side,
            # duplicate separator, missing suffix, whitespace, non-ASCII mailbox.
            for email in ("invalid", "@b.c", "a@", "a@@b.c", "a@b", "a@b.", "a@.b", "a b@c.d", "鵬@b.c"):
                request("POST", "/users", 400, {"name": "Invalid", "email": email})
            assert search(name="Invalid") == []
            # Missing fields, wrong JSON type, and malformed syntax are separate input classes.
            for value in ({"name": "Missing"}, {"email": "a@b.c"}, {"name": 1, "email": "a@b.c"}):
                request("POST", "/users", 400, value)
            request("POST", "/users", 400, raw="{")
            # Typed extraction must preserve the API's 400 response, including
            # the missing/unsupported media types that the default extractor rejects with 415.
            for content_type in (None, "text/plain"):
                assert request("POST", "/users", 400, {"name": "Alice", "email": "a@b.c"},
                               content_type=content_type) == b"invalid request"
            assert request("POST", "/users", 400) == b"invalid request"


            # PostgreSQL VARCHAR(40) accepts 39/40 characters and rejects 41.
            for length in (39, 40):
                create("n" * length, f"name{length}@example.com")
            request("POST", "/users", 500, {"name": "n" * 41, "email": "failed@example.com"})
            assert search(email="failed@example.com") == []
            create("After failed write", "recovered@example.com")
            create('Quote " and Unicode 鵬', "quoted@example.com")

            # Simultaneous independent creates must produce distinct persistent IDs.
            with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
                users = list(pool.map(lambda i: create("Concurrent", f"parallel{i}@example.com"), range(5)))
            assert len({u["id"] for u in users}) == 5
            assert {u["id"] for u in search(name="Concurrent")} == {u["id"] for u in users}

            os.killpg(server.pid, signal.SIGTERM)
            assert server.wait(timeout=10) == 0
            log.seek(0)
            lines = log.read().splitlines()
            assert lines.count(MARKER) == (len(requests) if contract_alloc else 0), lines[-20:]
        except Exception:
            log.seek(0)
            print(log.read(), file=sys.stderr)
            raise
        finally:
            if server.poll() is None:
                os.killpg(server.pid, signal.SIGKILL)
                server.wait(timeout=10)
            log.close()
