#!/usr/bin/env python3
"""M13b: the guide examples behave as the guides describe."""
import http.client
import subprocess
import sys
import pathlib
import socket

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, stop  # noqa: E402

CASES = {
    "routing": [
        ("GET", "/", None, {}, 200, b"home\n", {}),
        ("GET", "/users/42", None, {}, 200, b"user 42\n", {}),
        ("DELETE", "/users/42", None, {}, 200, b"deleted 42\n", {}),
        # A static segment wins over a parameter, whatever the order.
        ("GET", "/users/me", None, {}, 200, b"me\n", {}),
        ("GET", "/files/docs/a.txt", None, {}, 200, b"file docs/a.txt\n", {}),
        ("GET", "/api/health", None, {}, 200, b"ok\n", {}),
        ("GET", "/nope", None, {}, 404, b"nothing here\n", {}),
        # HEAD falls back to GET; the body is not sent.
        ("HEAD", "/", None, {}, 200, b"", {}),
        ("POST", "/users/42", None, {}, 405, None, {"allow": "GET, HEAD, DELETE"}),
    ],
    "extractors": [
        ("POST", "/lists/groceries/items", b'{"name":"milk"}', {"content-type": "application/json"}, 201, b"added milk to groceries\n", {}),
        ("POST", "/lists/groceries/items", b"not json", {"content-type": "application/json"}, 400, None, {}),
        ("GET", "/lists/groceries/search?q=green%20tea", None, {}, 200, b"searching groceries for green tea, page 1\n", {}),
        ("GET", "/lists/groceries/search?q=tea&page=2", None, {}, 200, b"searching groceries for tea, page 2\n", {}),
        ("GET", "/lists/groceries/search?page=2", None, {}, 400, None, {}),
        ("GET", "/lists/groceries/raw?q=tea", None, {}, 200, b"raw groceries q=tea\n", {}),
    ],
    "middleware": [
        ("GET", "/public", None, {}, 200, b"public\n", {"x-served-by": "roxum"}),
        ("GET", "/private", None, {}, 401, b"missing x-api-key\n", {"x-served-by": "roxum"}),
        ("GET", "/private", None, {"x-api-key": "k"}, 200, b"private\n", {"x-served-by": "roxum"}),
        ("GET", "/missing", None, {}, 404, None, {"x-served-by": "roxum"}),
    ],
}


def check_json_media_type(port):
    # Valid syntax classes, missing/wrong media type, malformed parameters,
    # and duplicate singleton fields. A withheld Expect body proves early rejection.
    cases = [
        (["application/json"], 201),
        (["Application/JSON; charset=utf-8"], 201),
        (["application/problem+json; profile=\"a;b\""], 201),
        ([], 415),
        (["text/plain"], 415),
        (["application/jsonx"], 415),
        (["application/+json"], 415),
        (["application/a+json"], 201),
        (["application/ab+json"], 201),
        (["application/json; charset="], 415),
        (["application/json; charset=\"unfinished"], 415),
        (["application/json, application/json"], 415),
        (["application/json", "application/json"], 415),
        (["application/json", "text/plain"], 415),
    ]
    for values, expected in cases:
        body = b'{"name":"milk"}'
        headers = "".join(f"Content-Type: {value}\r\n" for value in values)
        # Exercise buffered requests, then rejection before a withheld body
        # is sent: one the host would prebuffer and one
        # larger than its 64 KiB prebuffer threshold.
        for withheld_length in ([None, len(body), 65537] if expected == 415 else [None]):
            withheld = withheld_length is not None
            length = withheld_length if withheld else len(body)
            head = ("POST /lists/groceries/items HTTP/1.1\r\nHost: x\r\n"
                    + headers + f"Content-Length: {length}\r\nConnection: close\r\n")
            if withheld:
                head += "Expect: 100-continue\r\n"
            with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
                sock.sendall(head.encode() + b"\r\n" + (b"" if withheld else body))
                with sock.makefile("rb") as stream:
                    # Inspect the first status, without HTTPResponse hiding 100.
                    first = stream.readline()
                    if first.split()[1] != str(expected).encode():
                        raise RuntimeError(f"Content-Type {values}: {first!r}, expected {expected}")
                    stream.read()


def main():
    example, executable = sys.argv[1], sys.argv[2]
    server = subprocess.Popen(
        [executable],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        start_new_session=True,
    )
    try:
        port = read_port(server)
        if example == "extractors":
            check_json_media_type(port)
        for method, route, body, headers, status, expected_body, expected_headers in CASES[example]:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            connection.request(method, route, body=body, headers=headers)
            response = connection.getresponse()
            actual = response.read()
            connection.close()
            if response.status != status:
                raise RuntimeError(f"{example} {method} {route}: status {response.status}, expected {status}")
            if expected_body is not None and actual != expected_body:
                raise RuntimeError(f"{example} {method} {route}: body {actual!r}")
            for name, value in expected_headers.items():
                if response.getheader(name) != value:
                    raise RuntimeError(f"{example} {method} {route}: {name} is {response.getheader(name)!r}")
    finally:
        # SIGKILL follows if SIGTERM is ignored, so a stuck server does not
        # hide the failure above or outlive the test.
        stop(server)


if __name__ == "__main__":
    main()
