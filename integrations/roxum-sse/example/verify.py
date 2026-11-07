#!/usr/bin/env python3
import http.client
import os
import signal
import subprocess
import sys
import time
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "tests" / "support"))
from roxum_process import read_port, ready_workers  # noqa: E402


def open_stream(port, path, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.request("GET", path, headers=headers or {})
    response = connection.getresponse()
    if response.status != 200 or response.getheader("content-type") != "text/event-stream":
        raise RuntimeError(f"{path}: unexpected response {response.status}")
    return connection, response


def read_event(response):
    """The next event's lines, without the blank line that ends it."""
    lines = []
    while True:
        line = response.readline()
        if not line:
            raise RuntimeError(f"stream ended inside an event: {lines!r}")
        if line == b"\n":
            return lines
        lines.append(line.rstrip(b"\n"))


def check(label, actual, expected):
    if actual != expected:
        raise RuntimeError(f"{label}: expected {expected!r}, got {actual!r}")


def check_ticks(port):
    """`retry` goes first, events come every 100 ms without drifting, and
    a client that connects again goes on after its `Last-Event-ID`."""
    connection, response = open_stream(port, "/ticks")
    check("ticks: retry", read_event(response), [b"retry: 3000"])
    started = time.monotonic()
    for number in range(6):
        check(f"ticks: event {number}", read_event(response), [f"id: {number}".encode(), f"data: tick {number}".encode()])
    elapsed = time.monotonic() - started
    if not 0.4 <= elapsed < 0.9:
        raise RuntimeError(f"ticks: 5 intervals of 100 ms took {elapsed:.2f} s")
    connection.close()
    connection, response = open_stream(port, "/ticks", {"Last-Event-ID": "41"})
    read_event(response)
    check("ticks: after Last-Event-ID", read_event(response), [b"id: 42", b"data: tick 42"])
    connection.close()


def check_keep_alive(port):
    """A quiet stream gets a comment line at the keep-alive interval."""
    connection, response = open_stream(port, "/quiet")
    check("quiet: event", read_event(response), [b"data: quiet"])
    started = time.monotonic()
    check("quiet: keep-alive", read_event(response), [b":"])
    elapsed = time.monotonic() - started
    if not 0.1 <= elapsed < 0.6:
        raise RuntimeError(f"quiet: keep-alive after {elapsed:.2f} s, every 0.2 s")
    connection.close()


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
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        connection.request("GET", "/events", headers={"Connection": "close"})
        response = connection.getresponse()
        body = response.read()
        if response.status != 200:
            raise RuntimeError(f"unexpected status: {response.status}")
        if response.getheader("content-type") != "text/event-stream":
            raise RuntimeError("missing SSE content type")
        if response.getheader("cache-control") != "no-cache":
            raise RuntimeError("missing SSE cache policy")
        expected = b"data: first\n\nretry: 1000\ndata: second\ndata: line\n\n"
        if body != expected:
            raise RuntimeError(f"unexpected SSE body: {body!r}")
        connection.close()
        # Encoded event length straddles the HTTP chunk maximum. The SSE
        # delimiter and following event must survive byte-for-byte.
        for boundary, length in [("below", 65527), ("at", 65528), ("above", 65529), ("lines", 65529)]:
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            connection.request("GET", "/large?" + boundary, headers={"Connection": "close"})
            response = connection.getresponse()
            if response.status != 200:
                raise RuntimeError(f"unexpected status {response.status}")
            expected = (b"data: \n" * (length + 1) + b"\n" if boundary == "lines"
                        else b"data: " + b"x" * length + b"\n\n")
            body = response.read()
            if body != expected + b"data: after\n\n":
                raise RuntimeError(f"unexpected body {body!r}")
            connection.close()
        check_ticks(port)
        print("ticks, retry, and Last-Event-ID: PASS")
        check_keep_alive(port)
        print("keep-alive: PASS")
        # A stream without end ends cleanly when the server stops: a body
        # cut without its end raises IncompleteRead.
        connection, response = open_stream(port, "/ticks")
        read_event(response)
        read_event(response)
        started = time.monotonic()
        os.killpg(server.pid, signal.SIGTERM)
        response.read()
        if time.monotonic() - started > 1:
            raise RuntimeError("the stream did not end when the server stopped")
        connection.close()
        print("a stream ends on a drain: PASS")
        if server.wait(timeout=6) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=6)


if __name__ == "__main__":
    main()
