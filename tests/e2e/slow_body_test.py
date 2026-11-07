#!/usr/bin/env python3
"""A client that sends its request body slowly must not stall other requests.

Each thread runs its event loop and its Roc work. The loop reads a whole
body (up to 64 KiB, decoded for chunked framing) before handing the request
to the Roc work, so a handler never waits on a slow sender.
"""
import os
import signal
import socket
import subprocess
import sys
import time
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, expected_thread_count, ready_workers  # noqa: E402

BODY_BYTES = 64 * 1024
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


def quick_request(port):
    started = time.monotonic()
    with socket.create_connection(("127.0.0.1", port), timeout=2) as client:
        client.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        head, _ = read_response(client)
    if not head.startswith(b"HTTP/1.1 200 "):
        raise RuntimeError(f"unexpected response: {head[:64]!r}")
    return time.monotonic() - started


def body_for(index):
    return bytes((index + offset) % 251 for offset in range(BODY_BYTES))


def check_slow_bodies(port, worker_count):
    slow = []
    try:
        # More stalled bodies than Roc threads. Before the loop read bodies,
        # each held a Roc thread until the 30 s body timeout.
        for index in range(worker_count * 2):
            client = socket.create_connection(("127.0.0.1", port), timeout=5)
            client.sendall(
                b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n" % BODY_BYTES
                + body_for(index)[:100]
            )
            slow.append(client)
        time.sleep(0.5)

        for _ in range(worker_count * 4):
            elapsed = quick_request(port)
            if elapsed > 1:
                raise RuntimeError(f"request waited {elapsed:.2f}s behind slow request bodies")

        # Each body arrives in pieces and is echoed whole; the connection
        # stays usable.
        for index, client in enumerate(slow):
            body = body_for(index)
            third = BODY_BYTES // 3
            for piece in (body[100:third], body[third : 2 * third], body[2 * third :]):
                client.sendall(piece)
        for index, client in enumerate(slow):
            head, echoed = read_response(client)
            if not head.startswith(b"HTTP/1.1 200 ") or echoed != body_for(index):
                raise RuntimeError(f"unexpected echo for slow body {index}: {head[:40]!r}, {len(echoed)} bytes")
            client.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
            head, _ = read_response(client)
            if not head.startswith(b"HTTP/1.1 200 "):
                raise RuntimeError(f"connection {index} was not reusable: {head[:40]!r}")
    finally:
        for client in slow:
            client.close()


def check_slow_chunked_bodies(port, worker_count):
    slow = []
    try:
        # A chunked body is read by the loop too, so stalled chunked senders
        # do not hold the Roc threads either.
        for index in range(worker_count * 2):
            client = socket.create_connection(("127.0.0.1", port), timeout=5)
            client.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel")
            slow.append(client)
        time.sleep(0.5)
        for _ in range(worker_count * 4):
            elapsed = quick_request(port)
            if elapsed > 1:
                raise RuntimeError(f"request waited {elapsed:.2f}s behind slow chunked bodies")
        for index, client in enumerate(slow):
            tail = f"x{index}".encode()
            client.sendall(b"lo\r\n" + b"%x\r\n" % len(tail) + tail + b"\r\n0\r\n\r\n")
        for index, client in enumerate(slow):
            head, echoed = read_response(client)
            if not head.startswith(b"HTTP/1.1 200 ") or echoed != b"hello" + f"x{index}".encode():
                raise RuntimeError(f"unexpected echo for chunked body {index}: {head[:40]!r} {echoed!r}")
    finally:
        for client in slow:
            client.close()


def one_byte_chunks(data):
    return b"".join(b"1\r\n" + data[i : i + 1] + b"\r\n" for i in range(len(data))) + b"0\r\n\r\n"


def check_slow_expanded_chunked_bodies(port, worker_count):
    # One-byte chunks take 6 wire bytes per body byte: 30,000 body bytes are
    # about 176 KiB on the wire, more than a reader buffer (128 KiB). The loop
    # decodes as it reads, so these stall no Roc thread either.
    slow = []
    try:
        wires = []
        for index in range(worker_count * 2):
            wire = one_byte_chunks(body_for(index)[:30_000])
            client = socket.create_connection(("127.0.0.1", port), timeout=5)
            client.sendall(b"POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" + wire[:150_000])
            slow.append(client)
            wires.append(wire)
        time.sleep(0.5)
        for _ in range(worker_count * 4):
            elapsed = quick_request(port)
            if elapsed > 1:
                raise RuntimeError(f"request waited {elapsed:.2f}s behind slow expanded chunked bodies")
        for client, wire in zip(slow, wires):
            client.sendall(wire[150_000:])
        for index, client in enumerate(slow):
            head, echoed = read_response(client)
            if not head.startswith(b"HTTP/1.1 200 ") or echoed != body_for(index)[:30_000]:
                raise RuntimeError(f"unexpected echo for expanded chunked body {index}: {head[:40]!r}, {len(echoed)} bytes")
    finally:
        for client in slow:
            client.close()


def check_chunked_rejections(port):
    head = b"POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
    # Invalid framing, and framing past the wire limit (512 KiB) around one
    # byte of data.
    padding = 512 * 1024
    for wire, status in (
        (b"z\r\n", b"400"),
        (b"1;x=" + b"p" * padding + b"\r\nX\r\n0\r\n\r\n", b"413"),
    ):
        with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
            try:
                client.sendall(head + wire)
            except (BrokenPipeError, ConnectionResetError):
                pass
            response, _ = read_response(client)
            if not response.startswith(b"HTTP/1.1 " + status + b" "):
                raise RuntimeError(f"expected {status!r} for chunked body, got {response[:40]!r}")


def check_continue(port):
    # The loop sends 100 Continue once, before the body.
    with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
        body = body_for(7)
        client.sendall(
            b"POST /echo HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: %d\r\n\r\n" % BODY_BYTES
        )
        interim = b""
        while len(interim) < len(CONTINUE):
            part = client.recv(len(CONTINUE) - len(interim))
            if not part:
                raise RuntimeError("connection closed before 100 Continue")
            interim += part
        if interim != CONTINUE:
            raise RuntimeError(f"expected 100 Continue, got {interim!r}")
        client.sendall(body)
        head, echoed = read_response(client)
        if not head.startswith(b"HTTP/1.1 200 ") or echoed != body:
            raise RuntimeError(f"unexpected response after 100 Continue: {head[:40]!r}")

    # Over the route's body limit: 413 at once, without 100 Continue.
    with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
        client.sendall(
            b"POST /limited-upload HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: %d\r\n\r\n" % (BODY_BYTES + 1)
        )
        head, _ = read_response(client)
        if not head.startswith(b"HTTP/1.1 413 "):
            raise RuntimeError(f"expected 413 without 100 Continue, got {head[:40]!r}")


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
        # Load sized to hold every thread of the process at once.
        worker_count = expected_thread_count()
        check_slow_bodies(port, worker_count)
        check_slow_chunked_bodies(port, worker_count)
        check_slow_expanded_chunked_bodies(port, worker_count)
        check_chunked_rejections(port)
        check_continue(port)

        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=6) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=6)


if __name__ == "__main__":
    main()
