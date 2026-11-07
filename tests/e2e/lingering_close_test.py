#!/usr/bin/env python3
"""A connection closed after an error response must not be reset.

The client is still sending when the server answers 413, 431, or 400. If
the server closed with request bytes unread, the kernel would send RST and
the client could lose the response it had not read yet. The server shuts
down its write side and discards what the client still sends first.
"""
import os
import signal
import socket
import subprocess
import sys
import time
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, ready_workers  # noqa: E402

REPEATS = 20


def exchange(port, request):
    """Sends `request` at once and reads until the server closes. Returns the
    bytes read and how long the close took after the response began."""
    with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
        client.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 256 * 1024)
        try:
            client.sendall(request)
        except (BrokenPipeError, ConnectionResetError) as error:
            raise RuntimeError(f"the server reset the connection while the request was sent: {error}")
        response = bytearray()
        started = None
        while True:
            try:
                part = client.recv(65536)
            except ConnectionResetError:
                raise RuntimeError(f"connection reset after {len(response)} response bytes: {bytes(response[:40])!r}")
            if started is None:
                started = time.monotonic()
            if not part:
                return bytes(response), time.monotonic() - started
            response.extend(part)


def expect_status(port, request, status):
    for _ in range(REPEATS):
        response, close_wait = exchange(port, request)
        if not response.startswith(f"HTTP/1.1 {status} ".encode()):
            raise RuntimeError(f"expected {status}, got {response[:40]!r}")
        # The client already sent everything, so the server's FIN follows
        # the response at once rather than after the linger deadline.
        if close_wait > 1:
            raise RuntimeError(f"close after {status} took {close_wait:.2f}s")


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

        # 413: the declared body is over the route's limit; 48 KiB of it is
        # sent.
        expect_status(
            port,
            b"POST /limited-upload HTTP/1.1\r\nHost: x\r\nContent-Length: 1000000\r\n\r\n" + b"x" * (48 * 1024),
            413,
        )
        # 431: a 40 KiB field, then 24 KiB more that the server never parses.
        expect_status(
            port,
            b"GET / HTTP/1.1\r\nHost: x\r\nX-Fill: " + b"a" * (40 * 1024) + b"\r\n\r\n" + b"b" * (24 * 1024),
            431,
        )
        # 400: an invalid target, followed by 40 KiB of pipelined bytes.
        expect_status(
            port,
            b"GET /a/../b HTTP/1.1\r\nHost: x\r\n\r\n" + b"GET / HTTP/1.1\r\nHost: x\r\n\r\n" * 1400,
            400,
        )

        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=6) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=6)


if __name__ == "__main__":
    main()
