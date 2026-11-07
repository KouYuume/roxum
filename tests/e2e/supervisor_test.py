#!/usr/bin/env python3
import os
import http.client
import email.utils
import datetime
import signal
import socket
import subprocess
import sys
import time
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, children, expected_thread_count  # noqa: E402


def request(port):
    with socket.create_connection(("127.0.0.1", port), timeout=2) as client:
        client.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        response = bytearray()
        while True:
            part = client.recv(4096)
            if not part:
                break
            response.extend(part)
    if not response.startswith(b"HTTP/1.1 200 "):
        raise RuntimeError(f"unexpected response: {response!r}")


def read_keep_alive_response(client):
    response = bytearray()
    while b"\r\n\r\n" not in response:
        part = client.recv(4096)
        if not part:
            raise RuntimeError("connection closed before response head")
        response.extend(part)
    head, body = response.split(b"\r\n\r\n", 1)
    if not head.startswith(b"HTTP/1.1 200 "):
        raise RuntimeError(f"unexpected response head: {bytes(head)!r}")
    length = next(int(line.split(b":", 1)[1]) for line in head.split(b"\r\n") if line.lower().startswith(b"content-length:"))
    while len(body) < length:
        part = client.recv(4096)
        if not part:
            raise RuntimeError("connection closed before response body")
        body.extend(part)


def held_connections(port, worker_count):
    # The event loop holds idle keep-alive connections without occupying the
    # Roc thread, so connections beyond the worker count are served at once.
    held = []
    try:
        for _ in range(worker_count * 4):
            client = socket.create_connection(("127.0.0.1", port), timeout=2)
            held.append(client)
            client.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
            read_keep_alive_response(client)
        request(port)
        for client in held:
            client.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
            read_keep_alive_response(client)
    finally:
        for client in held:
            client.close()


def regression_responses(port):
    def get(target, host="different.example", expected_status=200):
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        connection.request("GET", target, headers={"Host": host, "Connection": "close"})
        response = connection.getresponse()
        body = response.read()
        assert response.status == expected_status, (target, response.status)
        dates = [value for name, value in response.getheaders() if name.lower() == "date"]
        assert len(dates) == 1, dates
        stamp = email.utils.parsedate_to_datetime(dates[0])
        assert abs((datetime.datetime.now(datetime.timezone.utc) - stamp).total_seconds()) < 30
        connection.close()
        return body

    assert get("/query-value?a&b=1") == b"a%20b%26c%3Dd%23e%2Bf|a%26b%3D1|a%20b%2Fc%3Fd"
    assert get("/authority") == b"different.example"
    for target, authority in [
        ("http://authority.example/authority", b"authority.example"),
        ("HTTP://authority.example:8080/authority?q=1", b"authority.example:8080"),
        ("https://[::1]:443/authority", b"[::1]:443"),
    ]:
        assert get(target) == authority
    get("/missing", expected_status=404)
    get("/stream")
    # This malformed Host is rejected by the host before entering Roc.
    get("/", host="bad host", expected_status=400)


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
        request(port)
        initial = children(server.pid)
        # One process by default, serving on a thread per CPU.
        if len(initial) != 1:
            raise RuntimeError(f"expected 1 worker process, found {initial}")
        regression_responses(port)
        held_connections(port, expected_thread_count())
        os.kill(initial[0], signal.SIGKILL)

        deadline = time.monotonic() + 3
        replacement = []
        while time.monotonic() < deadline:
            replacement = [pid for pid in children(server.pid) if pid not in initial]
            if replacement:
                try:
                    request(port)
                    break
                except OSError:
                    pass
            time.sleep(0.02)
        else:
            raise RuntimeError("worker was not restored on the original port")

        os.killpg(server.pid, signal.SIGTERM)
        return_code = server.wait(timeout=6)
        if return_code != 0:
            raise RuntimeError(f"supervisor shutdown returned {return_code}")
    finally:
        if server.poll() is None:
            try:
                os.killpg(server.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                server.wait(timeout=6)
            except subprocess.TimeoutExpired:
                os.killpg(server.pid, signal.SIGKILL)
                raise RuntimeError("supervisor did not stop workers within 5 seconds")


if __name__ == "__main__":
    main()
