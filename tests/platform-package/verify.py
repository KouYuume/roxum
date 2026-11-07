#!/usr/bin/env python3
import os
import signal
import socket
import subprocess
import sys


def request(port):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
        client.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        response = bytearray()
        while True:
            part = client.recv(4096)
            if not part:
                break
            response.extend(part)
    head, body = bytes(response).split(b"\r\n\r\n", 1)
    if not head.startswith(b"HTTP/1.1 200 "):
        raise RuntimeError(f"unexpected status: {head!r}")
    if b"x-roxum-integration: m9p1\r\n" not in head.lower() + b"\r\n":
        raise RuntimeError(f"integration header missing: {head!r}")
    if body != b"ok":
        raise RuntimeError(f"unexpected body: {body!r}")


def main():
    server = subprocess.Popen(
        [sys.argv[1]],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        # The supervisor prints the port once every worker is ready.
        port = int(server.stdout.readline().strip())
        request(port)
        os.killpg(server.pid, signal.SIGTERM)
        stderr = server.communicate(timeout=6)[1]
        if server.returncode != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}: {stderr}")
        if "[INFO] m9p1" not in stderr:
            raise RuntimeError(f"effectful package wrapper did not log: {stderr!r}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=6)


if __name__ == "__main__":
    main()
