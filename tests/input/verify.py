#!/usr/bin/env python3
"""M24 phase 4: handlers with a typed argument, and extractors in a body, in
one backend and allocator."""
import gzip
import http.client
import os
import pathlib
import signal
import socket
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, ready_workers  # noqa: E402

JSON = {"content-type": "application/json"}
FORM = {"content-type": "application/x-www-form-urlencoded"}
ITEM = b'{"name":"a","count":2}'
# One raw block holding "hello"; the standard library has no zstd.
ZSTD_HELLO = bytes.fromhex("28b52ffd2005290000") + b"hello"


MULTIPART = {"content-type": "multipart/form-data; boundary=B"}


def part(name, value, head=""):
    return f'--B\r\nContent-Disposition: form-data; name="{name}"{head}\r\n\r\n'.encode() + value + b"\r\n"


FORM_BODY = (part("title", b"t") + part("icon", b"\x89\r\n", '; filename="a.png"\r\nContent-Type: image/png')
             + part("tags", b"x") + part("tags", b"y") + b"--B--\r\n")


def fields(total):
    """A form of `total` fields, two of them required."""
    return part("title", b"t") + part("icon", b"x") + b"".join(part(f"k{i}", b"1") for i in range(total - 2)) + b"--B--"


def big_form(size):
    return part("title", b"t") + part("icon", b"\xab" * size) + b"--B--"


def pairs(count):
    return "&".join(f"k{i}=1" for i in range(count))


# (method, path, headers, body, status, expected body or None)
CASES = [
    # Query: decoding, a repeated name in any position, left out, the types.
    ("GET", "/query?q=green%20tea+x&tag=a&page=2&tag=b&on=true", {}, None, 200, b"green tea x|2|a,b|true"),
    ("GET", "/query?q=a", {}, None, 200, b"a|-|-|-"),
    # Two fields with a string, repeated: a wrong free shows only on some threads (C-18).
    *[("GET", "/query-optional-str?count=3&theme=dark", {}, None, 200, b"3 dark")] * 40,
    ("GET", "/query-optional-str?count=3", {}, None, 200, b"3 none"),
    *[("GET", "/query-str?theme=dark&count=3", {}, None, 200, b"3 dark")] * 40,
    ("GET", "/query?q=", {}, None, 200, b"|-|-|-"),
    ("GET", "/query?q=a&unknown=1", {}, None, 200, b"a|-|-|-"),
    ("GET", "/query", {}, None, 400, None),
    ("GET", "/query?q=a&q=b", {}, None, 400, None),
    ("GET", "/query?q=a&page=x", {}, None, 400, None),
    ("GET", "/query?q=a&on=maybe", {}, None, 400, None),
    # The limit of 128 pairs: under, at, and over.
    ("GET", f"/query?q=a&{pairs(126)}", {}, None, 200, b"a|-|-|-"),
    ("GET", f"/query?q=a&{pairs(127)}", {}, None, 200, b"a|-|-|-"),
    ("GET", f"/query?q=a&{pairs(128)}", {}, None, 400, None),
    # Form: the media type, its case and parameters, and how it fails.
    # A field typed [Ok(_), Err(Reply)]: the handler runs, and Err holds the answer.
    ("POST", "/attempt-json", JSON, b'{"name":"a"}', 200, b"ok a"),
    ("POST", "/attempt-json", JSON, b"{", 200, b"err 400"),
    ("POST", "/attempt-json", JSON, b"{}", 200, b"err 400"),
    ("POST", "/attempt-json", {"content-type": "text/plain"}, b'{"name":"a"}', 200, b"err 415"),
    ("POST", "/attempt-json", {}, b'{"name":"a"}', 200, b"err 415"),
    ("POST", "/attempt-pass", JSON, b"{", 400, None),
    ("POST", "/attempt-pass", {"content-type": "text/plain"}, b"x", 415, None),
    # A field of another type answers for itself, and each field fails alone.
    ("POST", "/attempt-mixed/1?q=x", FORM, b"name=n", 200, b"1 x n"),
    ("POST", "/attempt-mixed/1", FORM, b"name=n", 200, b"1 400 n"),
    ("POST", "/attempt-mixed/1?q=x", {}, b"name=n", 200, b"1 x 415"),
    ("POST", "/attempt-mixed/1?q=x", FORM, b"other=n", 200, b"1 x 422"),
    ("POST", "/attempt-mixed/x?q=x", FORM, b"name=n", 400, None),
    ("POST", "/form", FORM, b"q=a+b&page=3", 200, b"a b|3|-|-"),
    ("POST", "/form", {"content-type": "Application/X-WWW-Form-Urlencoded; charset=utf-8"}, b"q=a", 200, b"a|-|-|-"),
    ("POST", "/form", {"content-type": "application/json"}, b"q=a", 415, None),
    ("POST", "/form", {}, b"q=a", 415, None),
    ("POST", "/form", FORM, b"page=3", 422, None),
    ("POST", "/form", FORM, b"q=a&page=x", 422, None),
    ("POST", "/form", FORM, f"q=a&{pairs(127)}".encode(), 200, b"a|-|-|-"),
    ("POST", "/form", FORM, f"q=a&{pairs(128)}".encode(), 413, None),
    # JSON: the media type, invalid JSON, and a value of another type.
    ("POST", "/json", JSON, ITEM, 200, b"a:2"),
    ("POST", "/json", {}, ITEM, 415, None),
    ("POST", "/json", JSON, b"bad", 400, None),
    ("POST", "/json", JSON, b'{"name":"a","count":"x"}', 400, None),
    ("POST", "/json", JSON, b'{"name":"a"}', 400, None),
    # Fields of several kinds; the path parameter's type.
    ("PUT", "/items/7?q=z", JSON, ITEM, 200, b"7:a:z"),
    ("PUT", "/items/x?q=z", JSON, ITEM, 400, None),
    ("GET", "/flags/true", {}, None, 200, b"yes"),
    ("GET", "/flags/false", {}, None, 200, b"no"),
    ("GET", "/flags/1", {}, None, 400, None),
    # A field for a parameter the route does not have is the app's bug.
    ("GET", "/no-param", {}, None, 500, None),
    # Headers.
    ("GET", "/headers", {"x-agent": "a", "x-retry": "3"}, None, 200, b"a:3"),
    ("GET", "/headers", {"x-agent": "a"}, None, 200, b"a:-"),
    ("GET", "/headers", {}, None, 400, None),
    ("GET", "/headers", {"x-agent": "a", "x-retry": "x"}, None, 400, None),
    # The whole body, twice on one route's extractors.
    ("POST", "/text", {}, b"hello", 200, b"hello"),
    ("POST", "/text", {}, b"\xff", 400, None),
    ("POST", "/bytes", {}, b"\xff\x00", 200, b"2"),
    # A field type of the app's, from what a stage provided, or a missing stage.
    ("POST", "/me", {**JSON, "x-user": "alice"}, ITEM, 200, b"alice:a"),
    ("POST", "/me", JSON, ITEM, 500, None),
    # Request bodies: none, gzip, zstd, and the limit of 16 decompressed bytes.
    ("POST", "/decompress", {}, b"plain", 200, b"plain"),
    ("POST", "/decompress", {"content-encoding": "identity"}, b"plain", 200, b"plain"),
    ("POST", "/decompress", {"content-encoding": "gzip"}, gzip.compress(b"hello"), 200, b"hello"),
    ("POST", "/decompress", {"content-encoding": "GZIP"}, gzip.compress(b"hello"), 200, b"hello"),
    ("POST", "/decompress", {"content-encoding": "zstd"}, ZSTD_HELLO, 200, b"hello"),
    ("POST", "/decompress", {"content-encoding": "gzip"}, gzip.compress(b"x" * 15), 200, b"x" * 15),
    ("POST", "/decompress", {"content-encoding": "gzip"}, gzip.compress(b"x" * 16), 200, b"x" * 16),
    ("POST", "/decompress", {"content-encoding": "gzip"}, gzip.compress(b"x" * 17), 413, None),
    ("POST", "/decompress", {"content-encoding": "gzip"}, b"not gzip", 400, None),
    ("POST", "/decompress", {"content-encoding": "br"}, b"x", 415, None),
    ("POST", "/decompress", {"content-encoding": "gzip, zstd"}, b"x", 415, None),
    # Multipart read whole.
    ("POST", "/profile", MULTIPART, FORM_BODY, 200, b"t|a.png|image/png|3|x,y"),
    ("POST", "/profile", {"content-type": "multipart/form-data"}, FORM_BODY, 415, None),
    ("POST", "/profile", JSON, FORM_BODY, 415, None),
    ("POST", "/profile", MULTIPART, b"no delimiter", 400, None),
    ("POST", "/profile", MULTIPART, FORM_BODY[:-4], 400, None),
    ("POST", "/profile", MULTIPART, b"--B\r\n" + b'Content-Disposition: form-data; name="title"\r\n\r\nt\r\n--B--', 422, None),
    # The limit of 128 fields: under, at, and over.
    ("POST", "/profile", MULTIPART, fields(127), 200, b"t|-|-|1|-"),
    ("POST", "/profile", MULTIPART, fields(128), 200, b"t|-|-|1|-"),
    ("POST", "/profile", MULTIPART, fields(129), 413, None),
    # Within a route's larger whole-body limit; past the default one is below.
    ("POST", "/profile-large", MULTIPART, big_form(3 * 1024 * 1024), 200, b"t|-|-|3145728|-"),
    # Multipart field by field.
    ("POST", "/upload", MULTIPART, FORM_BODY, 200, b"title=1;icon=3;tags=1;tags=1;"),
    # Past the 64 KiB the loop receives itself, so the handler reads as it arrives.
    ("POST", "/upload", MULTIPART, big_form(256 * 1024), 200, b"title=1;icon=262144;"),
    ("POST", "/upload", JSON, FORM_BODY, 415, None),
    ("POST", "/upload", MULTIPART, FORM_BODY[:-4], 400, None),
    # Extractors in a handler's body.
    ("POST", "/body?q=z", JSON, ITEM, 200, b"a:z"),
    ("POST", "/body", JSON, ITEM, 400, None),
]


def first_status_withheld(port, path, headers, length=3):
    head = f"POST {path} HTTP/1.1\r\nHost: x\r\nContent-Length: {length}\r\nExpect: 100-continue\r\nConnection: close\r\n{headers}\r\n"
    with socket.create_connection(("127.0.0.1", port), timeout=10) as client:
        client.sendall(head.encode())
        with client.makefile("rb") as stream:
            first = stream.readline()
            stream.read()
    return first


def main():
    contract_alloc = os.environ.get("ROXUM_CONTRACT_ALLOC") == "1"
    server = subprocess.Popen([sys.argv[1]], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        port = read_port(server)
        ready_workers(server)
        for method, path, headers, body, status, expected in CASES:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=120)
            connection.request(method, path, body=body, headers={"Connection": "close", **headers})
            response = connection.getresponse()
            data = response.read()
            connection.close()
            label = f"{method} {path[:60]} {headers}"
            if response.status != status:
                raise RuntimeError(f"{label}: status {response.status} {data!r}, expected {status}")
            if expected is not None and data != expected:
                raise RuntimeError(f"{label}: body {data!r}, expected {expected!r}")
        # require_form and an unsupported coding refuse before a withheld body.
        first = first_status_withheld(port, "/form-early", "Content-Type: text/plain\r\n")
        if not first.startswith(b"HTTP/1.1 415 "):
            raise RuntimeError(f"require_form: first status {first!r}")
        first = first_status_withheld(port, "/decompress", "Content-Encoding: br\r\n")
        if not first.startswith(b"HTTP/1.1 415 "):
            raise RuntimeError(f"unsupported coding: first status {first!r}")
        first = first_status_withheld(port, "/profile-early", "Content-Type: text/plain\r\n")
        if not first.startswith(b"HTTP/1.1 415 "):
            raise RuntimeError(f"require_multipart: first status {first!r}")
        # Past the whole-body limit: answered without taking the body.
        first = first_status_withheld(port, "/profile", "Content-Type: multipart/form-data; boundary=B\r\n", 3 * 1024 * 1024)
        if not first.startswith(b"HTTP/1.1 413 "):
            raise RuntimeError(f"whole-body limit: first status {first!r}")
        # The boundary cut anywhere by the network: sent in small pieces.
        with socket.create_connection(("127.0.0.1", port), timeout=10) as client:
            client.sendall(b"POST /upload HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Type: multipart/form-data; boundary=B\r\nContent-Length: %d\r\n\r\n" % len(FORM_BODY))
            for index in range(len(FORM_BODY)):
                client.sendall(FORM_BODY[index:index + 1])
                time.sleep(0.001)
            data = b""
            while True:
                piece = client.recv(4096)
                if not piece:
                    break
                data += piece
        if not data.endswith(b"title=1;icon=3;tags=1;tags=1;"):
            raise RuntimeError(f"byte by byte: {data!r}")
        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=10) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
        stderr = server.stderr.read()
        if contract_alloc and stderr.count("roxum-contract-request-ok") != len(CASES) + 5:
            raise RuntimeError(f"allocator markers for {len(CASES) + 5} requests: {stderr!r}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=10)


if __name__ == "__main__":
    main()
