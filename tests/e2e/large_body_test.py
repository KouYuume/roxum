#!/usr/bin/env python3
"""M21f: request bodies larger than the host receives before the handler.

A body over 64 KiB is handed to the handler unread, and its reads wait for
the client on a fiber. Checks: a large upload read as a stream does not grow
the worker's memory with its size, for Content-Length and chunked framing;
`100 Continue` goes out at the first read; slow uploads leave the threads
free for other requests; the limits of a route's `BodyLimit` layers answer
413.
"""
import os
import http.client
import pathlib
import signal
import socket
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import children, expected_thread_count, read_port, ready_workers  # noqa: E402

UPLOAD_BYTES = 64 * 1024 * 1024
CONTINUE = b"HTTP/1.1 100 Continue\r\n\r\n"


def read_response(client):
    """Reads one response with a Content-Length body; returns (head, body)."""
    data = bytearray()
    while b"\r\n\r\n" not in data:
        part = client.recv(65536)
        if not part:
            raise RuntimeError(f"connection closed before a response head: {bytes(data)!r}")
        data.extend(part)
    head, body = bytes(data).split(b"\r\n\r\n", 1)
    length = next(
        int(line.split(b":", 1)[1])
        for line in head.split(b"\r\n")
        if line.lower().startswith(b"content-length:")
    )
    body = bytearray(body)
    while len(body) < length:
        part = client.recv(65536)
        if not part:
            raise RuntimeError("connection closed inside a response body")
        body.extend(part)
    return head, bytes(body)


def resident_kib(pid):
    output = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout
    return int(output.strip() or 0)


def send_upload(client, chunked):
    """Sends UPLOAD_BYTES of body in 256 KiB parts."""
    part = b"u" * (256 * 1024)
    for _ in range(UPLOAD_BYTES // len(part)):
        client.sendall(b"%x\r\n%s\r\n" % (len(part), part) if chunked else part)
    if chunked:
        client.sendall(b"0\r\n\r\n")


def check_upload(port, worker, chunked):
    """A 64 MiB upload read as a stream: the count comes back, and the
    worker's memory does not grow with the body."""
    framing = b"Transfer-Encoding: chunked" if chunked else b"Content-Length: %d" % UPLOAD_BYTES
    before = resident_kib(worker)
    peak = before
    with socket.create_connection(("127.0.0.1", port), timeout=30) as client:
        client.sendall(b"POST /upload HTTP/1.1\r\nHost: x\r\n" + framing + b"\r\n\r\n")
        sender = threading.Thread(target=send_upload, args=(client, chunked))
        sender.start()
        while sender.is_alive():
            peak = max(peak, resident_kib(worker))
            time.sleep(0.05)
        sender.join()
        head, body = read_response(client)
    label = "chunked" if chunked else "Content-Length"
    if not head.startswith(b"HTTP/1.1 200 ") or body != str(UPLOAD_BYTES).encode():
        raise RuntimeError(f"{label} upload: {head[:40]!r} {body!r}")
    grown = (peak - before) / 1024
    if grown > 16:
        raise RuntimeError(f"{label} upload of 64 MiB grew the worker by {grown:.1f} MiB")


def check_continue(port):
    """`100 Continue` comes at the handler's first read of a large body."""
    with socket.create_connection(("127.0.0.1", port), timeout=10) as client:
        length = 1024 * 1024
        client.sendall(b"POST /upload HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: %d\r\n\r\n" % length)
        interim = b""
        while len(interim) < len(CONTINUE):
            part = client.recv(len(CONTINUE) - len(interim))
            if not part:
                raise RuntimeError("connection closed before 100 Continue")
            interim += part
        if interim != CONTINUE:
            raise RuntimeError(f"expected 100 Continue, got {interim!r}")
        client.sendall(b"c" * length)
        head, body = read_response(client)
        if not head.startswith(b"HTTP/1.1 200 ") or body != str(length).encode():
            raise RuntimeError(f"after 100 Continue: {head[:40]!r} {body!r}")


def quick_request(port):
    started = time.monotonic()
    with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
        client.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        head, _ = read_response(client)
    if not head.startswith(b"HTTP/1.1 200 "):
        raise RuntimeError(f"unexpected response: {head[:64]!r}")
    return time.monotonic() - started


def check_slow_uploads(port):
    """Uploads that stop half way, more than the threads, while other
    requests are answered at once; then they finish."""
    length = 1024 * 1024
    clients = []
    try:
        for _ in range(expected_thread_count() + 2):
            client = socket.create_connection(("127.0.0.1", port), timeout=10)
            client.sendall(b"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n" % length)
            client.sendall(b"s" * (length // 2))
            clients.append(client)
        time.sleep(0.3)
        for _ in range(5):
            elapsed = quick_request(port)
            if elapsed > 0.5:
                raise RuntimeError(f"a request took {elapsed:.2f} s beside slow uploads")
        for client in clients:
            client.sendall(b"s" * (length - length // 2))
        for client in clients:
            head, body = read_response(client)
            if not head.startswith(b"HTTP/1.1 200 ") or body != str(length).encode():
                raise RuntimeError(f"slow upload: {head[:40]!r} {body!r}")
    finally:
        for client in clients:
            client.close()


def expect_status(port, request, status):
    with socket.create_connection(("127.0.0.1", port), timeout=10) as client:
        try:
            client.sendall(request)
        except (BrokenPipeError, ConnectionResetError):
            pass
        head, _ = read_response(client)
    if not head.startswith(b"HTTP/1.1 %d " % status):
        raise RuntimeError(f"expected {status} for {request[:60]!r}, got {head[:40]!r}")


def check_route_limits(port):
    """A route's `BodyLimit` layers: at the limit and one byte over."""
    limit = 65536
    for length, status in ((limit, 200), (limit + 1, 413)):
        body = b"l" * length
        expect_status(port, b"POST /limited-upload HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n" % length + body, status)
        chunked = b"%x\r\n%s\r\n0\r\n\r\n" % (length, body)
        expect_status(port, b"POST /limited-upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" + chunked, status)
    json = b'{"name":"roxum"}'
    for length, status in ((1024, 200), (1025, 413)):
        body = json + b" " * (length - len(json))
        expect_status(port, b"POST /limited-json HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n" % length + body, status)


def check_upload_keepalive(port):
    # Nearest valid sizes below/at/above the prebuffer boundary. Withhold
    # the body until 100 Continue so the streamed path must wait for input.
    for chunked in (False, True):
        for length in (65535, 65536, 65537):
            body = b'{"name":"roxum"}' + b" " * (length - 16)
            with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
                framing = (b"Transfer-Encoding: chunked\r\n" if chunked else
                           b"Content-Length: %d\r\n" % length)
                client.sendall(b"POST /extract/id HTTP/1.1\r\nHost: x\r\n"
                               b"Content-Type: application/json\r\nExpect: 100-continue\r\n"
                               + framing + b"\r\n")
                interim = b""
                while not interim.endswith(b"\r\n\r\n"):
                    part = client.recv(1)
                    if not part:
                        raise RuntimeError("closed before 100 Continue")
                    interim += part
                if interim != CONTINUE:
                    raise RuntimeError(f"unexpected interim {interim!r}")
                if chunked:
                    # Cross the prebuffer threshold before terminating the body.
                    client.sendall(b"%x\r\n" % length + body + b"\r\n0\r\n\r\n")
                else:
                    client.sendall(body)
                response = http.client.HTTPResponse(client)
                response.begin()
                actual = response.read()
                if response.status != 200 or actual != b"id||roxum":
                    raise RuntimeError(f"upload response: {response.status} {actual!r}")
                for _ in range(2):
                    client.sendall(b"POST /extract/id HTTP/1.1\r\nHost: x\r\n"
                                   b"Content-Type: application/json\r\nContent-Length: 16\r\n\r\n"
                                   b'{"name":"roxum"}')
                    following = http.client.HTTPResponse(client)
                    following.begin()
                    actual = following.read()
                    if following.status != 200 or actual != b"id||roxum":
                        raise RuntimeError(f"reused response: {following.status} {actual!r}")


def main():
    server = subprocess.Popen(
        [sys.argv[1]],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        start_new_session=True,
    )
    try:
        port = read_port(server)
        ready_workers(server)
        workers = children(server.pid)
        if len(workers) != 1:
            raise RuntimeError(f"expected one worker, found {workers}")
        check_upload(port, workers[0], chunked=False)
        print("a 64 MiB Content-Length upload read as a stream: PASS")
        check_upload(port, workers[0], chunked=True)
        print("a 64 MiB chunked upload read as a stream: PASS")
        check_continue(port)
        print("100 Continue at the first read: PASS")
        check_slow_uploads(port)
        print("slow uploads beside other requests: PASS")
        check_upload_keepalive(port)
        print("keep-alive after upload across the prebuffer boundary: PASS")
        check_route_limits(port)
        print("route body limits: PASS")
        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=6) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=6)


if __name__ == "__main__":
    main()
