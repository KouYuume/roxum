#!/usr/bin/env python3
"""M22a and M22b: files served from a root with Reply.file and Files.serve.

The test prepares public/ in the server's working directory, with links that
stay inside it and links that lead out of it. Checks: bytes, Content-Type,
Content-Length and HEAD, 404 for what is missing, a directory, or out of the
root, a large file without the worker's memory growing, other requests going
on beside a client that does not read, and no file left open by clients
that go half way.
"""
import http.client
import os
import pathlib
import platform
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import children, read_port, ready_workers, stop  # noqa: E402

BIG_BYTES = 32 * 1024 * 1024


def check(label, actual, expected):
    if actual != expected:
        raise RuntimeError(f"{label}: expected {expected!r}, got {actual!r}")


def fetch(port, path, method="GET"):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        connection.request(method, path)
        response = connection.getresponse()
        body = response.read()
        return response.status, response.getheader("Content-Type"), response.getheader("Content-Length"), body
    finally:
        connection.close()


def resident_kib(pid):
    output = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout
    return int(output.strip() or 0)


def open_files(pid):
    if platform.system() == "Linux":
        return len(os.listdir(f"/proc/{pid}/fd"))
    output = subprocess.run(["lsof", "-p", str(pid)], capture_output=True, text=True).stdout
    return len(output.splitlines())


# Empty/small bodies and the nearest lengths around the 64 KiB transfer cap.
TRANSFER_SIZES = (0, 1, 65535, 65536, 65537)


def prepare(directory):
    base = pathlib.Path(directory)
    public = base / "public"
    (public / "sub").mkdir(parents=True)
    (public / "a.txt").write_text("hello")
    for size in TRANSFER_SIZES:
        (public / f"boundary-{size}.bin").write_bytes(bytes(index % 251 for index in range(size)))
    (public / "sub" / "b.css").write_text("body{}")
    (public / "big.bin").write_bytes(os.urandom(1024) * (BIG_BYTES // 1024))
    outside = base / "outside"
    outside.mkdir()
    (outside / "secret.txt").write_text("secret")
    (public / "link_in.txt").symlink_to("a.txt")
    (public / "link_sub").symlink_to("sub")
    (public / "link_out.txt").symlink_to(outside / "secret.txt")
    (public / "link_out_dir").symlink_to(outside)
    (public / "link_up.txt").symlink_to("../outside/secret.txt")
    (public / "sub" / "index.html").write_text("<p>index</p>")
    (public / "app.js").write_text("console.log(1)")
    (public / "app.js.br").write_bytes(b"brotli-bytes")
    (public / "app.js.gz").write_bytes(b"gzip-bytes")
    (public / "plain.css").write_text("p{}")
    return public


def check_answers(port, public):
    for size in TRANSFER_SIZES:
        path = f"/files/boundary-{size}.bin"
        status, _, length, body = fetch(port, path)
        check(f"transfer boundary {size}", (status, length, body),
              (200, str(size), (public / f"boundary-{size}.bin").read_bytes()))
    check("a file", fetch(port, "/files/a.txt"), (200, "text/plain; charset=utf-8", "5", b"hello"))
    check("HEAD", fetch(port, "/files/a.txt", "HEAD"), (200, "text/plain; charset=utf-8", "5", b""))
    check("a nested file", fetch(port, "/files/sub/b.css")[::3], (200, b"body{}"))
    check("the app's content-type", fetch(port, "/typed/a.txt")[1], "application/x-test")
    check("a link inside", fetch(port, "/files/link_in.txt")[::3], (200, b"hello"))
    check("a directory link inside", fetch(port, "/files/link_sub/b.css")[::3], (200, b"body{}"))
    for path in ("/files/missing.txt", "/files/", "/files/%2E%2E/outside/secret.txt",
                 "/files/sub/%2E%2E/%2E%2E/outside/secret.txt", "/files/%2Fetc%2Fhosts", "/files/link_out.txt",
                 "/files/link_out_dir/secret.txt", "/files/link_up.txt", "/files/a.txt%00.png"):
        status = fetch(port, path)[0]
        # The host refuses a target with an encoded `..`, `/`, or NUL (400)
        # before routing.
        if status not in (400, 404) or (status == 400 and "%" not in path):
            raise RuntimeError(f"{path}: expected 404, got {status}")
    # The connection is kept after a file.
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    for _ in range(3):
        connection.request("GET", "/files/a.txt")
        response = connection.getresponse()
        check("keep-alive", (response.status, response.read()), (200, b"hello"))
    connection.close()


def request(port, path, headers=None, method="GET"):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        connection.request(method, path, headers=headers or {})
        response = connection.getresponse()
        return response.status, {k.lower(): v for k, v in response.getheaders()}, response.read()
    finally:
        connection.close()


def check_http_features(port):
    """M22b: validators, conditional requests, ranges, directories, and
    precompressed files, for Files.serve and Reply.file alike."""
    for prefix in ("/serve", "/files"):
        status, headers, body = request(port, f"{prefix}/a.txt")
        check(f"{prefix}: 200", (status, body), (200, b"hello"))
        tag, modified = headers["etag"], headers["last-modified"]
        if not tag.startswith('W/"') or not modified.endswith(" GMT"):
            raise RuntimeError(f"{prefix}: validators {tag!r} {modified!r}")
        check(f"{prefix}: accept-ranges", headers.get("accept-ranges"), "bytes")
        check(f"{prefix}: If-None-Match", request(port, f"{prefix}/a.txt", {"If-None-Match": tag})[::2], (304, b""))
        check(f"{prefix}: If-None-Match among others", request(port, f"{prefix}/a.txt", {"If-None-Match": f'"x", {tag}'})[0], 304)
        check(f"{prefix}: If-None-Match *", request(port, f"{prefix}/a.txt", {"If-None-Match": "*"})[0], 304)
        check(f"{prefix}: another ETag", request(port, f"{prefix}/a.txt", {"If-None-Match": '"x"'})[::2], (200, b"hello"))
        check(f"{prefix}: If-Modified-Since", request(port, f"{prefix}/a.txt", {"If-Modified-Since": modified})[0], 304)
        check(f"{prefix}: an older If-Modified-Since", request(port, f"{prefix}/a.txt", {"If-Modified-Since": "Thu, 01 Jan 1970 00:00:00 GMT"})[0], 200)
        # If-None-Match decides when both are present.
        check(f"{prefix}: If-None-Match first", request(port, f"{prefix}/a.txt", {"If-None-Match": '"x"', "If-Modified-Since": modified})[0], 200)
        check(f"{prefix}: HEAD 304", request(port, f"{prefix}/a.txt", {"If-None-Match": tag}, "HEAD")[0], 304)

        status, headers, body = request(port, f"{prefix}/a.txt", {"Range": "bytes=1-3"})
        check(f"{prefix}: a range", (status, body, headers.get("content-range"), headers.get("content-length")), (206, b"ell", "bytes 1-3/5", "3"))
        check(f"{prefix}: a suffix range", request(port, f"{prefix}/a.txt", {"Range": "bytes=-2"})[::2], (206, b"lo"))
        check(f"{prefix}: an open range", request(port, f"{prefix}/a.txt", {"Range": "bytes=3-"})[::2], (206, b"lo"))
        status, headers, _ = request(port, f"{prefix}/a.txt", {"Range": "bytes=9-"})
        check(f"{prefix}: an unsatisfiable range", (status, headers.get("content-range")), (416, "bytes */5"))
        check(f"{prefix}: several ranges", request(port, f"{prefix}/a.txt", {"Range": "bytes=0-0,2-2"})[::2], (200, b"hello"))
        check(f"{prefix}: If-Range with the time", request(port, f"{prefix}/a.txt", {"Range": "bytes=0-0", "If-Range": modified})[::2], (206, b"h"))
        check(f"{prefix}: If-Range with the weak ETag", request(port, f"{prefix}/a.txt", {"Range": "bytes=0-0", "If-Range": tag})[::2], (200, b"hello"))
        check(f"{prefix}: a range of HEAD", request(port, f"{prefix}/a.txt", {"Range": "bytes=0-0"}, "HEAD")[0], 200)

        status, headers, _ = request(port, f"{prefix}/sub?x=1")
        check(f"{prefix}: a directory redirects", (status, headers.get("location")), (301, f"{prefix}/sub/?x=1"))
        status, headers, body = request(port, f"{prefix}/sub/")
        check(f"{prefix}: a directory's index", (status, headers.get("content-type"), body), (200, "text/html; charset=utf-8", b"<p>index</p>"))
        check(f"{prefix}: a directory without an index", request(port, f"{prefix}/link_sub/../outside/")[0] in (400, 404), True)

    for accept, body, coding in (("br, gzip", b"brotli-bytes", "br"), ("gzip", b"gzip-bytes", "gzip"),
                                 ("br;q=0, gzip", b"gzip-bytes", "gzip"), ("identity", b"console.log(1)", None),
                                 ("", b"console.log(1)", None)):
        status, headers, received = request(port, "/pre/app.js", {"Accept-Encoding": accept} if accept else {})
        check(f"precompressed for {accept!r}",
              (status, received, headers.get("content-encoding"), headers.get("content-type"), headers.get("vary")),
              (200, body, coding, "text/javascript; charset=utf-8", "accept-encoding"))
    status, headers, received = request(port, "/pre/plain.css", {"Accept-Encoding": "br"})
    check("no precompressed file", (status, received, headers.get("content-encoding"), headers.get("vary")), (200, b"p{}", None, "accept-encoding"))
    status, headers, _ = request(port, "/pre/app.js", {"Accept-Encoding": "br"})
    check("the precompressed file's own ETag", headers["etag"].endswith('-br"'), True)
    check("without precompressed files, no Vary", request(port, "/serve/app.js", {"Accept-Encoding": "br"})[1].get("vary"), None)


def check_big(port, worker, public):
    before = resident_kib(worker)
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    connection.request("GET", "/files/big.bin")
    response = connection.getresponse()
    check("big: Content-Length", response.getheader("Content-Length"), str(BIG_BYTES))
    received = bytearray()
    peak = before
    while True:
        part = response.read(1024 * 1024)
        if not part:
            break
        received.extend(part)
        peak = max(peak, resident_kib(worker))
    connection.close()
    expected = (public / "big.bin").read_bytes()
    if bytes(received) != expected:
        first = next((index for index, (a, b) in enumerate(zip(received, expected)) if a != b), min(len(received), len(expected)))
        raise RuntimeError(f"big: {len(received)} bytes received, they differ from byte {first}")
    grown = (peak - before) / 1024
    if grown > 16:
        raise RuntimeError(f"big: a 32 MiB file grew the worker by {grown:.1f} MiB")


def check_slow_reader(port):
    """Clients that take a big file and do not read: other requests go on."""
    clients = []
    try:
        for _ in range(8):
            client = socket.create_connection(("127.0.0.1", port), timeout=10)
            client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            client.sendall(b"GET /files/big.bin HTTP/1.1\r\nHost: x\r\n\r\n")
            clients.append(client)
        time.sleep(0.3)
        for _ in range(5):
            started = time.monotonic()
            check("quick", fetch(port, "/quick")[0], 200)
            elapsed = time.monotonic() - started
            if elapsed > 0.5:
                raise RuntimeError(f"a request took {elapsed:.2f} s beside clients that do not read")
    finally:
        for client in clients:
            client.close()


def check_no_open_files(port, worker):
    """Clients that go half way leave no file open."""
    baseline = open_files(worker)
    for _ in range(20):
        client = socket.create_connection(("127.0.0.1", port), timeout=10)
        client.sendall(b"GET /files/big.bin HTTP/1.1\r\nHost: x\r\n\r\n")
        client.recv(65536)
        client.close()
    deadline = time.monotonic() + 5
    while open_files(worker) > baseline + 2:
        if time.monotonic() > deadline:
            raise RuntimeError(f"files left open: {open_files(worker)} descriptors, {baseline} before")
        time.sleep(0.1)


def run_checks(server, port, public):
    workers = children(server.pid)
    check_answers(port, public)
    print("files, HEAD, links, and paths out of the root: PASS")
    check_http_features(port)
    print("validators, conditional requests, ranges, directories, precompressed files: PASS")
    check_big(port, workers[0], public)
    print("a 32 MiB file: PASS")
    check_slow_reader(port)
    print("clients that do not read: PASS")
    check_no_open_files(port, workers[0])
    print("clients that go half way: PASS")
    if stop(server) != 0:
        raise RuntimeError(f"server shutdown returned {server.returncode}")


def main(executable):
    with tempfile.TemporaryDirectory() as directory:
        public = prepare(directory)
        with tempfile.TemporaryFile() as output:
            server = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE, stderr=output,
                                      text=True, start_new_session=True)
            try:
                port = read_port(server)
                ready_workers(server)
                run_checks(server, port, public)
            except Exception:
                output.seek(0)
                sys.stderr.write(output.read().decode(errors="replace")[-4000:])
                raise
            finally:
                if server.poll() is None:
                    server.kill()
                    server.wait(timeout=6)
        # A root that cannot be opened stops startup.
        (pathlib.Path(directory) / "public").rename(pathlib.Path(directory) / "elsewhere")
        server = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, start_new_session=True)
        _, error = server.communicate(timeout=30)
        if server.returncode == 0 or "public cannot be opened" not in error:
            raise RuntimeError(f"startup without public: {server.returncode} {error!r}")
        print("a missing root stops startup: PASS")


if __name__ == "__main__":
    main(sys.argv[1])
