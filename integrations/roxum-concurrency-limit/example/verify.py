#!/usr/bin/env python3
"""roxum-concurrency-limit: a limit and the requests just under, at, and over it,
keys that share and keep apart, a full limiter, and a key that comes back however
its request ended, in one backend and allocator."""
import contextlib
import http.client
import pathlib
import socket
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "tests" / "support"))
from roxum_process import read_port, stop  # noqa: E402

def get(port, path):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    connection.request("GET", path)
    response = connection.getresponse()
    body = response.read()
    connection.close()
    return response.status, response.headers.get("retry-after"), body


def status(port, path):
    return get(port, path)[0]


def expect(port, path, wanted):
    actual = status(port, path)
    if actual != wanted:
        raise RuntimeError(f"{path}: {actual}, expected {wanted}")


def expect_soon(port, path, wanted):
    """For a key given back after the client's end of it: not at once, but soon."""
    deadline = time.monotonic() + 5
    while True:
        actual = status(port, path)
        if actual == wanted:
            return
        if time.monotonic() > deadline:
            raise RuntimeError(f"{path}: still {actual}, expected {wanted}")
        time.sleep(0.02)


def held(resources, port, *paths):
    """Acknowledge admission, then hold each key by withholding its body."""
    started = []
    for path in paths:
        client = resources.enter_context(socket.create_connection(("127.0.0.1", port), timeout=10))
        client.sendall(
            f"GET {path} HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n"
            "Expect: 100-continue\r\nConnection: close\r\n\r\n".encode()
        )
        head = bytearray()
        while not head.endswith(b"\r\n\r\n"):
            byte = client.recv(1)
            if not byte:
                raise RuntimeError(f"{path}: disconnected before admission: {head!r}")
            head.extend(byte)
            if len(head) > 8192:
                raise RuntimeError(f"{path}: oversized admission response")
        if head != b"HTTP/1.1 100 Continue\r\n\r\n":
            raise RuntimeError(f"{path}: not admitted: {head!r}")
        started.append(client)
    return started


def statuses(started):
    # Release every body before waiting for responses, keeping holders concurrent.
    for client in started:
        client.sendall(b"x")
    result = []
    for client in started:
        with http.client.HTTPResponse(client) as response:
            response.begin()
            response.read()
            result.append(response.status)
        client.close()
    return result


def main(executable):
    server = subprocess.Popen([executable], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, start_new_session=True)
    try:
        port = read_port(server)
        with contextlib.ExitStack() as resources:
            check_limit(resources, port)
            check_keys(resources, port)
            check_full(resources, port)
            check_ends(port)
            check_held_count(port)
    finally:
        stop(server)


def check_limit(resources, port):
    # Under the limit by one, at it, and over it, and the limit of 0.
    started = held(resources, port, "/three", "/three")
    expect(port, "/free", 200)
    third = held(resources, port, "/three")
    answer = get(port, "/three")
    if answer[:2] != (503, "1"):
        raise RuntimeError(f"/three over the limit: {answer}")
    if statuses(started + third) != [200, 200, 200]:
        raise RuntimeError("/three under its limit did not all pass")
    # And each one given back.
    if statuses(held(resources, port, "/three", "/three", "/three")) != [200, 200, 200]:
        raise RuntimeError("/three did not come back")
    expect(port, "/none", 503)


def check_keys(resources, port):
    started = held(resources, port, "/shared-a")
    expect(port, "/shared-b", 503)
    other = held(resources, port, "/apart")
    if statuses(started + other) != [200, 200]:
        raise RuntimeError("a key held apart was refused")
    if statuses(held(resources, port, "/no-limit", "/no-limit", "/no-limit")) != [200, 200, 200]:
        raise RuntimeError("a request with no limit was limited")


def check_full(resources, port):
    # Two keys fit; a third does not, and Allow lets it through unlimited. An old
    # key can still be held, and a key that ended makes room.
    started = held(resources, port, "/key/a", "/key/b")
    expect(port, "/key/c", 503)
    allowed = held(resources, port, "/allow/c")
    more = held(resources, port, "/key/a")
    if statuses(started + allowed + more) != [200, 200, 200, 200]:
        raise RuntimeError("a key that fits was refused")
    expect(port, "/key/c", 200)


def check_ends(port):
    # The handler crashed.
    expect(port, "/crash", 500)
    expect(port, "/crash", 500)

    # Finishing a finite stream gives its key back, including on reuse.
    for _ in range(2):
        answer = get(port, "/stream")
        if answer != (200, None, b"firstsecond"):
            raise RuntimeError(f"/stream did not finish: {answer}")

    # A running response producer holds its key until the client disconnects.
    client = socket.create_connection(("127.0.0.1", port), timeout=10)
    client.sendall(b"GET /endless HTTP/1.1\r\nHost: x\r\n\r\n")
    if not client.recv(4096).startswith(b"HTTP/1.1 200"):
        raise RuntimeError("/endless did not start")
    expect(port, "/endless", 503)
    client.close()
    client = socket.create_connection(("127.0.0.1", port), timeout=10)
    deadline = time.monotonic() + 5
    while True:
        client.sendall(b"GET /endless HTTP/1.1\r\nHost: x\r\n\r\n")
        head = client.recv(4096)
        if head.startswith(b"HTTP/1.1 200"):
            break
        if time.monotonic() > deadline:
            raise RuntimeError(f"/endless was not given back: {head!r}")
        client.close()
        time.sleep(0.02)
        client = socket.create_connection(("127.0.0.1", port), timeout=10)
    client.close()


def check_held_count(port):
    # A request may hold 8 keys; the ninth stops it, and it gives back the eight.
    expect(port, "/eight", 200)
    expect(port, "/eight", 200)
    expect(port, "/nine", 500)
    expect_soon(port, "/eight", 200)


if __name__ == "__main__":
    main(sys.argv[1])
