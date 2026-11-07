#!/usr/bin/env python3
import os
import select
import signal
import socket
import subprocess
import sys
import time
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "tests" / "support"))
from roxum_process import read_port, ready_workers  # noqa: E402


# The tracking host prints this marker after each request once every request
# allocation is freed and persistent allocations are back at their baseline.
def expect_contract_marker(server):
    readable, _, _ = select.select([server.stderr], [], [], 5)
    if not readable:
        raise RuntimeError("timed out waiting for allocator baseline marker")
    line = server.stderr.readline().strip()
    if line != "roxum-contract-request-ok":
        raise RuntimeError(f"unexpected allocator output: {line!r}")


def describe(server, port, headers):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
        request = "GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n"
        for name, value in headers:
            request += f"{name}: {value}\r\n"
        client.sendall((request + "\r\n").encode())
        response = bytearray()
        while True:
            part = client.recv(4096)
            if not part:
                break
            response.extend(part)
    head, body = bytes(response).split(b"\r\n\r\n", 1)
    if not head.startswith(b"HTTP/1.1 200 "):
        raise RuntimeError(f"unexpected response: {head!r}")
    if os.environ.get("ROXUM_CONTRACT_ALLOC") == "1":
        expect_contract_marker(server)
    address, peer_port, scheme, forwarded = body.decode().split(" ")
    return address, int(peer_port), scheme, int(forwarded)


def expect(actual, address, scheme, forwarded, port=None):
    if actual[0] != address or actual[2] != scheme or actual[3] != forwarded:
        raise RuntimeError(f"expected {address} {scheme} {forwarded}, got {actual!r}")
    if port is not None and actual[1] != port:
        raise RuntimeError(f"expected port {port}, got {actual!r}")
    if port is None and actual[1] == 0:
        raise RuntimeError(f"expected the real peer port, got {actual!r}")


def run(executable, checks):
    server = subprocess.Popen(
        [executable],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        port = read_port(server)
        ready_workers(server)
        checks(server, port)
        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=6) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=6)


def trusted_checks(server, port):
    # No forwarded fields: the peer itself.
    expect(describe(server, port, []), "127.0.0.1", "http", 0)
    # A trusted peer's client address replaces the peer; the port is unknown and
    # the raw chain is removed.
    expect(describe(server, port, [("X-Forwarded-For", "203.0.113.9")]), "203.0.113.9", "http", 0, port=0)
    # The nearest untrusted hop wins over a value the client prepended.
    expect(describe(server, port, [("X-Forwarded-For", "198.51.100.1, 203.0.113.9")]), "203.0.113.9", "http", 0, port=0)
    # Trusted hops are skipped across repeated fields.
    expect(
        describe(server, port, [("X-Forwarded-For", "198.51.100.1"), ("X-Forwarded-For", "10.0.0.9")]),
        "198.51.100.1",
        "http",
        0,
        port=0,
    )
    expect(describe(server, port, [("X-Forwarded-For", "[2001:db8::1]:443")]), "8193:3512:0:0:0:0:0:1", "http", 0, port=0)
    # The proxy's own fields other than the chain stay for the handler.
    expect(
        describe(server, port, [("X-Forwarded-For", "203.0.113.9"), ("X-Forwarded-Proto", "https"), ("X-Forwarded-Host", "app.example")]),
        "203.0.113.9",
        "https",
        2,
        port=0,
    )
    # An unparsable chain keeps the peer and removes every forwarding field.
    expect(describe(server, port, [("X-Forwarded-For", "unknown"), ("X-Forwarded-Proto", "https")]), "127.0.0.1", "http", 0)


def untrusted_checks(server, port):
    # From an untrusted peer no forwarding field reaches the handler.
    expect(
        describe(
            server,
            port,
            [
                ("X-Forwarded-For", "203.0.113.9"),
                ("X-Forwarded-Proto", "https"),
                ("X-Forwarded-Host", "evil.example"),
                ("X-Forwarded-Port", "443"),
                ("X-Real-IP", "203.0.113.9"),
                ("Forwarded", "for=203.0.113.9"),
            ],
        ),
        "127.0.0.1",
        "http",
        0,
    )


def main():
    run(sys.argv[1], trusted_checks)
    run(sys.argv[2], untrusted_checks)


if __name__ == "__main__":
    main()
