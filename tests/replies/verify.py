#!/usr/bin/env python3
"""M24 phase 5: helpers for replies, and links built from a route's pattern, in
one backend and allocator."""
import http.client
import os
import pathlib
import signal
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, ready_workers  # noqa: E402

# (path, status, body or None, {header: value})
CASES = [
    ("/trailers", 500, None, {}),
    ("/stream-trailers", 500, None, {}),
    ("/pdf", 200, b"%PDF", {"content-type": "application/pdf"}),
    ("/typed", 200, b"\x01", {"content-type": "text/csv; charset=utf-8"}),
    ("/computed", 200, b"\x01", {"content-type": "image/png"}),
    ("/computed-bad", 500, None, {}),
    # The status says what the client does next; the body is empty.
    ("/see-other", 303, b"", {"location": "/done"}),
    ("/temporary", 307, b"", {"location": "/done"}),
    ("/permanent", 308, b"", {"location": "https://example.com/a?b=c"}),
    ("/bad-location", 500, None, {}),
    # The reply keeps its type and body, plain or streamed.
    ("/attachment", 200, b"a,b", {
        "content-disposition": "attachment; filename=\"report.csv\"; filename*=UTF-8''report.csv",
        "content-type": "text/plain; charset=utf-8",
    }),
    ("/attachment-unicode", 200, b"x", {
        "content-disposition": "attachment; filename=\"download\"; filename*=UTF-8''%E5%B1%B1%E7%94%B0%20%22x%22.csv",
        "content-type": "text/csv",
    }),
    ("/attachment-stream", 200, b"x", {"content-disposition": "attachment; filename=\"big.bin\"; filename*=UTF-8''big.bin"}),
    ("/attachment-bad", 500, None, {}),
    # JSON Lines: a line for each value; none for no value.
    ("/json-record", 200, b'{"count":1,"name":"a\\"b\\ncd"}', {"content-type": "application/json"}),
    ("/json-nominal", 200, b'{"count":2,"name":"n"}', {"content-type": "application/json"}),
    ("/json-list", 200, b'[{"count":3,"name":"x"}]', {"content-type": "application/json"}),
    ("/json-empty-list", 200, b"[]", {"content-type": "application/json"}),
    ("/json-str", 200, b'"ok"', {"content-type": "application/json"}),
    ("/json-status", 400, b'{"error":"invalid_item"}', {"content-type": "application/json"}),
    ("/json-encoded", 200, b'{"ok":true}', {"content-type": "application/json"}),
    ("/lines-nominal", 200, b'{"count":4,"name":"l\\nm"}\n', {"content-type": "application/x-ndjson"}),
    ("/lines", 200, b'{"id":1}\n{"id":2}\n', {"content-type": "application/x-ndjson"}),
    ("/lines-empty", 200, b"", {"content-type": "application/x-ndjson"}),
    # A route from a Path value, and a link built from it.
    ("/articles/7", 200, b"article", {}),
    ("/link-number", 200, b"/articles/42", {}),
    ("/link/42", 200, b"/articles/42", {}),
    ("/link/a%2Fb", 200, b"/articles/a%2Fb", {}),
]


def main():
    contract_alloc = os.environ.get("ROXUM_CONTRACT_ALLOC") == "1"
    server = subprocess.Popen([sys.argv[1]], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        port = read_port(server)
        ready_workers(server)
        for path, status, body, headers in CASES:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            connection.request("GET", path, headers={"Connection": "close"})
            response = connection.getresponse()
            data = response.read()
            connection.close()
            if response.status != status:
                raise RuntimeError(f"{path}: status {response.status}, expected {status}")
            if body is not None and data != body:
                raise RuntimeError(f"{path}: body {data!r}, expected {body!r}")
            for name, value in headers.items():
                actual = response.getheaders()
                values = [v for n, v in actual if n.lower() == name]
                if values != [value]:
                    raise RuntimeError(f"{path}: {name} {values!r}, expected {value!r}")
        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=10) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
        stderr = server.stderr.read()
        assert stderr.count("Response trailers require a finite response") == 1, stderr
        assert "writer must not run" not in stderr, stderr
        # The rejected stream reply fails the handler before its writer runs.
        # The crash cleanup path does not emit a normal completion marker.
        expected_completions = len(CASES) - 1
        if contract_alloc and stderr.count("roxum-contract-request-ok") != expected_completions:
            raise RuntimeError(f"allocator markers for {expected_completions} completed requests: {stderr!r}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=10)


if __name__ == "__main__":
    main()
