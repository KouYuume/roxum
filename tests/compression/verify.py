#!/usr/bin/env python3
"""M22c and M22d: response bodies compressed with gzip by Compression.layer.

Checks which responses are compressed, that they decompress to the body
the app gave, `Vary`, `HEAD`, and that `q=0` and a missing
`Accept-Encoding` get the body as it is; that a body written as it
goes arrives part by part, a file is compressed whole but not for a range,
and a stream that ends on a drain still ends its gzip stream.
"""
import gzip
import http.client
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import zlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, ready_workers  # noqa: E402


def check(label, actual, expected):
    if actual != expected:
        raise RuntimeError(f"{label}: expected {expected!r}, got {actual!r}")


def request(port, path, headers=None, method="GET"):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        connection.request(method, path, headers=headers or {})
        response = connection.getresponse()
        return response.status, {k.lower(): v for k, v in response.getheaders()}, response.read()
    finally:
        connection.close()


GZIP = {"Accept-Encoding": "gzip, br"}


def check_streams(port):
    """A written body: each part arrives compressed before the next is
    written; SSE is left as it is."""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    connection.request("GET", "/stream", headers=GZIP)
    response = connection.getresponse()
    check("stream: head", (response.status, response.getheader("content-encoding"), response.getheader("content-length"),
                           response.getheader("vary")), (200, "gzip", None, "accept-encoding"))
    started = time.monotonic()
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    text = b""
    while b"part 1" not in text:
        part = response.read1(65536)
        if not part:
            raise RuntimeError("stream: ended before its first part")
        text += decoder.decompress(part)
    if time.monotonic() - started > 0.25:
        raise RuntimeError("stream: the first part waited for the next")
    rest = response.read()
    text += decoder.decompress(rest)
    connection.close()
    if not decoder.eof or text.count(b"part ") != 3:
        raise RuntimeError(f"stream: decompressed {text!r}")
    check("stream without gzip", request(port, "/stream")[1].get("content-encoding"), None)
    status, headers, body = request(port, "/events", GZIP)
    check("SSE", (status, headers.get("content-encoding"), body.count(b"part ")), (200, None, 3))


def check_files(port, public):
    page = (public / "page.html").read_bytes()
    status, headers, body = request(port, "/file/page.html", GZIP)
    check("file: compressed", (status, headers.get("content-encoding"), headers.get("content-length"), headers.get("vary")),
          (200, "gzip", None, "accept-encoding"))
    check("file: decompresses", gzip.decompress(body), page)
    if len(body) * 4 > len(page):
        raise RuntimeError(f"file: {len(body)} compressed bytes of {len(page)}")
    check("file: as it is without gzip", request(port, "/file/page.html")[::2], (200, page))
    status, headers, body = request(port, "/file/page.html", GZIP, "HEAD")
    check("file: HEAD", (status, headers.get("content-encoding"), body), (200, "gzip", b""))
    status, headers, body = request(port, "/file/page.html", {**GZIP, "Range": "bytes=0-9"})
    check("file: a range is not compressed", (status, headers.get("content-encoding"), body), (206, None, page[:10]))
    check("file: an image", request(port, "/file/photo.png", GZIP)[1].get("content-encoding"), None)
    check("file: 32 bytes or less", request(port, "/file/tiny.txt", GZIP)[1].get("content-encoding"), None)


def check_drained(server, port):
    """A compressed stream that ends on a drain ends its gzip stream, with
    the keep-alive bytes compressed in it."""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    connection.request("GET", "/beats", headers=GZIP)
    response = connection.getresponse()
    check("beats: head", response.getheader("content-encoding"), "gzip")
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    text = b""
    while text.count(b"beat") < 2:
        text += decoder.decompress(response.read1(65536))
    os.killpg(server.pid, signal.SIGTERM)
    text += decoder.decompress(response.read())
    connection.close()
    if not decoder.eof or not text.startswith(b"first\n") or b"never" in text:
        raise RuntimeError(f"beats: decompressed {text!r}, ended: {decoder.eof}")
    check("beats: exit status", server.wait(timeout=10), 0)


def main(executable):
    directory = tempfile.mkdtemp()
    public = pathlib.Path(directory) / "public"
    public.mkdir()
    (public / "page.html").write_bytes(b"<p>a page that compresses well</p>\n" * 2000)
    (public / "photo.png").write_bytes(b"\x89PNG" + b"\x00" * 4000)
    (public / "tiny.txt").write_bytes(b"tiny")
    server = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                              start_new_session=True)
    try:
        port = read_port(server)
        ready_workers(server)

        status, plain_headers, plain = request(port, "/json")
        check("/json without Accept-Encoding", (status, plain_headers.get("content-encoding"), plain_headers.get("vary")),
              (200, None, "accept-encoding"))
        for path in ("/json", "/large", "/svg"):
            status, headers, body = request(port, path, GZIP)
            check(f"{path} compressed", (status, headers.get("content-encoding"), headers.get("vary")), (200, "gzip", "accept-encoding"))
            check(f"{path} decompresses", gzip.decompress(body), request(port, path)[2])
            check(f"{path} Content-Length", int(headers["content-length"]), len(body))
            if len(body) * 2 > len(request(port, path)[2]):
                raise RuntimeError(f"{path}: {len(body)} compressed bytes")
        status, headers, body = request(port, "/json", GZIP, "HEAD")
        _, get_headers, get_body = request(port, "/json", GZIP)
        check("HEAD", (status, headers.get("content-encoding"), headers.get("content-length"), body),
              (200, "gzip", str(len(get_body)), b""))

        status, headers, body = request(port, "/error", GZIP)
        check("an error reply", (status, headers.get("content-encoding")), (400, "gzip"))
        if b"roxum" not in gzip.decompress(body):
            raise RuntimeError("an error reply: the body differs")

        for path, label in (("/small", "a body of 32 bytes or less"), ("/image", "an image"),
                            ("/encoded", "an encoded body"), ("/narrow", "below the route's above_bytes"),
                            ("/plain", "a route without the layer")):
            status, headers, body = request(port, path, GZIP)
            expected_encoding = "br" if path == "/encoded" else None
            check(label, (status, headers.get("content-encoding")), (200, expected_encoding))
        check("no Vary without the layer", request(port, "/plain", GZIP)[1].get("vary"), None)
        check("no Vary for an image", request(port, "/image", GZIP)[1].get("vary"), None)

        for accept in ("gzip;q=0", "br", "identity"):
            status, headers, body = request(port, "/json", {"Accept-Encoding": accept})
            check(f"Accept-Encoding: {accept}", (headers.get("content-encoding"), body), (None, plain))

        print("bodies in memory: PASS")
        check_streams(port)
        print("bodies written as they go: PASS")
        check_files(port, public)
        print("files: PASS")
        check_drained(server, port)
        print("a stream that ends on a drain: PASS")
    finally:
        if server.poll() is None:
            server.kill()
            server.wait(timeout=6)
        shutil.rmtree(directory)


if __name__ == "__main__":
    main(sys.argv[1])
