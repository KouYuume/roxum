#!/usr/bin/env python3
"""The boundaries of the acceptance contracts in
reports/2026-11-01-axum-parity-review.md, in one backend and allocator. Layer
scope is in tests/router-scopes, thread counts in tests/listen-options, and the
limits other than requests in progress in tests/admission."""
import gzip
import http.client
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, stop  # noqa: E402

JSON = {"content-type": "application/json"}


def check(label, actual, expected):
    if actual != expected:
        raise RuntimeError(f"{label}: {actual!r}, expected {expected!r}")


def raw(port, data, timeout=5):
    """Sends bytes and reads to the end of the connection. Returns (the first
    status line's code, all the bytes)."""
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as client:
        client.sendall(data)
        received = b""
        try:
            while chunk := client.recv(65536):
                received += chunk
        except (ConnectionResetError, socket.timeout):
            pass
    return (int(received.split(b" ", 2)[1]) if received else None), received


def body_of(received):
    return received.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in received else b""


def post(port, path, body, headers=None):
    head = "".join(f"{name}: {value}\r\n" for name, value in (headers or {}).items())
    return raw(port, f"POST {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Length: {len(body)}\r\n{head}\r\n".encode() + body)


def chunked(port, path, body, size=4096):
    pieces = b"".join(f"{len(body[at:at + size]):x}\r\n".encode() + body[at:at + size] + b"\r\n" for at in range(0, len(body), size))
    return raw(port, f"POST {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n".encode() + pieces + b"0\r\n\r\n")


def get(port, path, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    connection.request("GET", path, headers=headers or {})
    response = connection.getresponse()
    body = response.read()
    connection.close()
    return response.status, response.headers, body


def json_media_types(port):
    good = b'{"name":"a"}'
    for media_type, status in (
        (None, 415),
        ("text/plain", 415),
        ("application/json", 200),
        ("APPLICATION/JSON", 200),
        ("application/json; charset=utf-8", 200),
        ("application/problem+json", 200),
        ("application/jsonx", 415),
    ):
        headers = {"content-type": media_type} if media_type else {}
        check(f"json as {media_type}", post(port, "/json", good, headers)[0], status)
    # Both are 400 until Json.parse tells them apart.
    check("json syntax", post(port, "/json", b"{", JSON)[0], 400)
    check("json type", post(port, "/json", b'{"name":1}', JSON)[0], 400)
    check("json missing field", post(port, "/json", b"{}", JSON)[0], 400)


def whole_limit(port):
    limit = 1024
    for size, status, answer in ((limit - 1, 200, b"1023 same"), (limit, 200, b"1024 same"), (limit + 1, 413, None)):
        for label, send in (("length", post), ("chunked", chunked)):
            actual, received = send(port, "/whole", b"x" * size)
            check(f"whole {size} by {label}", actual, status)
            if answer is not None:
                check(f"whole {size} by {label}: body", body_of(received), answer)
    # With Expect: 100-continue, a body known to be too long is refused before
    # the client sends it, and one that fits is asked for.
    for size, first in ((limit, 100), (limit + 1, 413)):
        with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
            client.sendall(f"POST /whole HTTP/1.1\r\nHost: x\r\nConnection: close\r\nExpect: 100-continue\r\nContent-Length: {size}\r\n\r\n".encode())
            check(f"expect at {size}", int(client.recv(65536).split(b" ", 2)[1]), first)


def read_ahead(port):
    for size in (65535, 65536, 65537):
        body = b"x" * size
        for label, send in (("length", post), ("chunked", chunked)):
            actual, received = send(port, "/ahead", body)
            check(f"ahead {size} by {label}", (actual, body_of(received)), (200, f"{size} same".encode()))
        # Refused however long the body is: with the body, and, when the client
        # waits to be asked for it, without.
        check(f"refused {size}", post(port, "/ahead-refused", body)[0], 403)
        check(f"refused {size} before the body", first_status(port, "/ahead-refused", size), 403)
        # A body that stops one byte short times out, wherever that falls.
        with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
            client.sendall(f"POST /ahead HTTP/1.1\r\nHost: x\r\nContent-Length: {size}\r\n\r\n".encode() + body[:-1])
            check(f"stalled {size}", int(client.recv(65536).split(b" ", 2)[1]), 408)


def first_status(port, path, size):
    """The status for a head alone, from a client that waits to be asked."""
    with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
        client.sendall(f"POST {path} HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: {size}\r\n\r\n".encode())
        return int(client.recv(65536).split(b" ", 2)[1])


def stream_limit(port):
    limit = 70000
    for size, status in ((limit - 1, 200), (limit, 200), (limit + 1, 413)):
        check(f"stream {size} by length", post(port, "/stream", b"x" * size)[0], status)
        check(f"stream {size} by chunks", chunked(port, "/stream", b"x" * size)[0], status)
    # Past every other limit, and held a part at a time.
    size = 8 * 1024 * 1024
    actual, received = post(port, "/stream-unlimited", b"x" * size)
    check("stream unlimited", (actual, body_of(received)), (200, str(size).encode()))


def paths(port):
    for path, status, body in (
        ("/path/static", 200, b"static"),
        ("/path/1", 200, b"id=1"),
        ("/path/1/edit", 200, b"id=1"),
        # A slash is not ignored.
        ("/path/static/", 404, None),
        ("/path/1/", 404, None),
        ("/path/", 404, None),
        # A catch-all takes the non-empty rest.
        ("/rest/a", 200, b"tail=a"),
        ("/rest/a/b/", 200, b"tail=a/b/"),
        ("/rest/", 404, None),
        ("/rest", 404, None),
        # Encoded: an unreserved byte is itself, an encoded slash stays within
        # its segment, and a dot segment is matched as a value.
        ("/path/%61", 200, b"id=a"),
        ("/path/stat%69c", 200, b"static"),
        ("/path/a%2Fb", 200, b"id=a/b"),
        ("/path/%2E%2E", 400, None),
        # Not UTF-8.
        ("/path/%FF", 400, None),
        ("/rest/%FF", 400, None),
    ):
        actual, _, received = get(port, path)
        if (actual, received if body is not None else None) != (status, body):
            print(f"path {path}: {actual} {received!r}, expected {status} {body!r}", file=sys.stderr)
            raise RuntimeError(f"path {path}")
    actual, headers, _ = get_with_method(port, "POST", "/path/static")
    check("path 405", (actual, headers.get("allow")), (405, "GET, HEAD"))


def get_with_method(port, method, path):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    connection.request(method, path)
    response = connection.getresponse()
    body = response.read()
    connection.close()
    return response.status, response.headers, body


def ranges(port):
    size = 10
    whole = b"0123456789"
    for value, status, body, content_range in (
        (f"bytes=0-{size - 1}", 206, whole, f"bytes 0-9/{size}"),
        (f"bytes=0-{size}", 206, whole, f"bytes 0-9/{size}"),
        (f"bytes={size - 1}-", 206, b"9", f"bytes 9-9/{size}"),
        (f"bytes={size}-", 416, b"", f"bytes */{size}"),
        (f"bytes={size + 1}-", 416, b"", f"bytes */{size}"),
        ("bytes=-1", 206, b"9", f"bytes 9-9/{size}"),
        (f"bytes=-{size}", 206, whole, f"bytes 0-9/{size}"),
        (f"bytes=-{size + 1}", 206, whole, f"bytes 0-9/{size}"),
        # Several ranges: the whole file.
        ("bytes=0-0,2-2", 200, whole, None),
        # Not a range this understands: the whole file.
        ("items=0-1", 200, whole, None),
    ):
        actual, headers, received = get(port, "/files/ten.txt", {"Range": value})
        check(f"range {value}", (actual, received if status != 416 else b"", headers.get("content-range")), (status, body, content_range))


def compression(port):
    threshold = 100
    # At or under the threshold no client gets it compressed, so nothing varies.
    for size, encoded, vary in ((threshold - 1, None, None), (threshold, None, None), (threshold + 1, "gzip", "accept-encoding")):
        status, headers, body = get(port, f"/sized/{size}", {"Accept-Encoding": "gzip"})
        check(f"size {size}", (status, headers.get("content-encoding"), headers.get("vary")), (200, encoded, vary))
        check(f"size {size}: body", gzip.decompress(body) if encoded else body, b"x" * size)
    for headers in ({"Accept-Encoding": "gzip;q=0"}, {}):
        status, answer, body = get(port, f"/sized/{threshold + 1}", headers)
        check(f"{headers}", (status, answer.get("content-encoding"), answer.get("vary"), body), (200, None, "accept-encoding", b"x" * (threshold + 1)))


def in_progress(port):
    """A limit of 3 requests in progress: C-1 and C run, C+1 is refused at once,
    and the slots come back when they finish and when a client goes away."""
    def hold(count, results):
        threads = []
        for _ in range(count):
            def call():
                results.append(get(port, "/sleep/700")[0])
            thread = threading.Thread(target=call)
            thread.start()
            threads.append(thread)
        return threads

    for count in (2, 3):
        results = []
        threads = hold(count, results)
        time.sleep(0.25)
        over = count == 3
        try:
            status = get(port, "/path/static")[0]
        except (http.client.HTTPException, OSError):
            status = None
        check(f"with {count} in progress", status in (503, None) if over else status == 200, True)
        for thread in threads:
            thread.join()
        check(f"the {count} in progress", results, [200] * count)
    time.sleep(0.2)
    check("after they finish", get(port, "/path/static")[0], 200)

    # A client that leaves: its request still ends, and its slot comes back.
    clients = [socket.create_connection(("127.0.0.1", port), timeout=5) for _ in range(3)]
    for client in clients:
        client.sendall(b"GET /sleep/300 HTTP/1.1\r\nHost: x\r\n\r\n")
    time.sleep(0.1)
    for client in clients:
        client.close()
    time.sleep(0.6)
    check("after clients left", get(port, "/path/static")[0], 200)


def main(executable):
    with tempfile.TemporaryDirectory() as directory:
        public = pathlib.Path(directory) / "public"
        public.mkdir()
        (public / "ten.txt").write_bytes(b"0123456789")
        errors = tempfile.TemporaryFile("w+")
        server = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE, stderr=errors, text=True, start_new_session=True)
        try:
            port = read_port(server)
            for step in (json_media_types, whole_limit, read_ahead, stream_limit, paths, ranges, compression, in_progress):
                step(port)
        finally:
            stop(server)


if __name__ == "__main__":
    main(sys.argv[1])
    print("acceptance contracts: PASS")
