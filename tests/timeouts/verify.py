#!/usr/bin/env python3
import os
import signal
import socket
import subprocess
import sys
import time
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, ready_workers  # noqa: E402

# The loop checks deadlines on a 250 ms tick, so a timeout is reported up to
# that much late; allow scheduling slack on top.
LATE_MARGIN = 0.75
# response_write_milliseconds in app.roc, in seconds.
WRITE_LIMIT = 5.0


def seconds_until_closed(client, limit):
    client.settimeout(limit)
    started = time.monotonic()
    try:
        data = client.recv(1)
    except socket.timeout:
        return None
    if data:
        raise RuntimeError(f"unexpected bytes before close: {data!r}")
    return time.monotonic() - started


def read_response(client):
    response = bytearray()
    while not response.endswith(b"ok"):
        part = client.recv(4096)
        if not part:
            raise RuntimeError("connection closed before response")
        response.extend(part)
    if not response.startswith(b"HTTP/1.1 200 "):
        raise RuntimeError(f"unexpected response: {bytes(response)!r}")


def check_limits(executable):
    server = subprocess.Popen(
        [executable],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        start_new_session=True,
    )
    try:
        port = read_port(server)
        ready_workers(server)

        # First request limit: 1 s.
        silent = socket.create_connection(("127.0.0.1", port), timeout=5)
        elapsed = seconds_until_closed(silent, 1 + LATE_MARGIN + 1)
        silent.close()
        if elapsed is None or not (1.0 - 0.05 <= elapsed <= 1.0 + LATE_MARGIN):
            raise RuntimeError(f"first request limit closed after {elapsed}")

        # Keep-alive limit: 3 s. Still open at 2 s, closed soon after 3 s.
        client = socket.create_connection(("127.0.0.1", port), timeout=5)
        client.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        read_response(client)
        if seconds_until_closed(client, 2.0) is not None:
            raise RuntimeError("keep-alive connection closed before 2 s")
        elapsed = seconds_until_closed(client, 1.0 + LATE_MARGIN + 1)
        client.close()
        if elapsed is None or not (elapsed <= 1.0 + LATE_MARGIN):
            raise RuntimeError(f"keep-alive limit closed {elapsed} s after the 2 s mark")

        # Body limit: 1 s from the end of the head. Nothing at 0.8 s; a 408
        # the client can read soon after 1 s.
        client = socket.create_connection(("127.0.0.1", port), timeout=5)
        started = time.monotonic()
        client.sendall(b"POST /body HTTP/1.1\r\nHost: x\r\nContent-Length: 10\r\n\r\nabc")
        client.settimeout(0.8)
        try:
            early = client.recv(1)
            raise RuntimeError(f"body limit answered before 0.8 s: {early!r}")
        except socket.timeout:
            pass
        client.settimeout(1.0 + LATE_MARGIN + 1)
        response = bytearray()
        while True:
            part = client.recv(4096)
            if not part:
                break
            response.extend(part)
        elapsed = time.monotonic() - started
        client.close()
        if not response.startswith(b"HTTP/1.1 408 "):
            raise RuntimeError(f"expected 408 after the body limit, got {bytes(response[:40])!r}")
        if not (1.0 - 0.05 <= elapsed <= 1.0 + LATE_MARGIN):
            raise RuntimeError(f"body limit answered after {elapsed:.2f} s")

        # Write limit: 5 s per chunk, not per response. A reader that takes
        # 64 KiB every 0.15 s needs about 10 s for the 4 MiB stream and still
        # gets all of it. It paces by the bytes it got, since how much one
        # recv returns differs between systems.
        client = socket.create_connection(("127.0.0.1", port), timeout=5)
        client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 * 1024)
        client.sendall(b"GET /stream HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        started = time.monotonic()
        response = bytearray()
        while True:
            part = client.recv(64 * 1024)
            if not part:
                break
            response.extend(part)
            time.sleep(0.15 * len(part) / (64 * 1024))
        elapsed = time.monotonic() - started
        client.close()
        received = response.partition(b"\r\n\r\n")[2].count(b"x")
        if received != 64 * 64 * 1024 or not response.endswith(b"0\r\n\r\n"):
            raise RuntimeError(f"stream stopped after {received} bytes in {elapsed:.2f} s")
        if elapsed <= WRITE_LIMIT:
            raise RuntimeError(f"the stream finished in {elapsed:.2f} s; it no longer outlasts the write limit")

        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=6) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=6)


def check_zero_rejected(executable):
    result = subprocess.run([executable], capture_output=True, text=True, timeout=30)
    if result.returncode == 0:
        raise RuntimeError("a zero timeout did not stop startup")
    if "every Server.Timeouts value must be at least 1 millisecond" not in result.stderr:
        raise RuntimeError(f"missing startup diagnostic: {result.stderr!r}")
    if result.stdout.strip():
        raise RuntimeError(f"a port was published: {result.stdout!r}")


def main():
    check_limits(sys.argv[1])
    check_zero_rejected(sys.argv[2])


if __name__ == "__main__":
    main()
