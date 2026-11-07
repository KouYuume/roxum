#!/usr/bin/env python3
"""Server.Limits.maximum_streams bounds the live streams in each worker.

The app allows one stream per worker process. With W workers, at most W
streams can be live at once, so of 4W stalled stream requests at least 3W
are answered 503, however the connections spread over the workers. Once the
streams end, new ones are served again.
"""
import pathlib
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, ready_workers, stop  # noqa: E402

WARNING = "the worker process already writes its maximum number of streams"


def read_head(client):
    data = bytearray()
    while b"\r\n\r\n" not in data:
        part = client.recv(4096)
        if not part:
            raise RuntimeError(f"connection closed before a response head: {bytes(data)!r}")
        data.extend(part)
    return bytes(data).split(b"\r\n\r\n", 1)[0]


def read_to_close(client):
    data = bytearray()
    while True:
        part = client.recv(65536)
        if not part:
            return bytes(data)
        data.extend(part)


def request(port, method, path):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
        client.sendall(f"{method} {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
        return read_to_close(client)


def check_limit(executable):
    with tempfile.TemporaryFile() as stderr:
        server = subprocess.Popen(
            [executable],
            stdout=subprocess.PIPE,
            stderr=stderr,
            text=True,
            start_new_session=True,
        )
        stalled = []
        try:
            port = read_port(server)
            worker_count = len(ready_workers(server))

            for _ in range(worker_count * 4):
                client = socket.create_connection(("127.0.0.1", port), timeout=5)
                # A small receive buffer keeps the stream from draining.
                client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                client.sendall(b"GET /long HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                stalled.append(client)
            statuses = [read_head(client).split(b" ", 2)[1] for client in stalled]
            served = statuses.count(b"200")
            rejected = statuses.count(b"503")
            if served + rejected != len(statuses):
                raise RuntimeError(f"unexpected statuses: {statuses}")
            if not 1 <= served <= worker_count:
                raise RuntimeError(f"{served} streams live at once with {worker_count} workers allowing one each")

            # Responses that are not streams, and a stream answering HEAD,
            # need no stream slot.
            for method, path in (("GET", "/"), ("HEAD", "/long")):
                response = request(port, method, path)
                if not response.startswith(b"HTTP/1.1 200 "):
                    raise RuntimeError(f"{method} {path} at the stream limit: {response[:40]!r}")

            for client in stalled:
                client.close()
            stalled.clear()

            # Closed streams give their slots back.
            for _ in range(worker_count * 2):
                deadline = time.monotonic() + 5
                while True:
                    response = request(port, "GET", "/short")
                    if response.startswith(b"HTTP/1.1 200 "):
                        break
                    if time.monotonic() > deadline:
                        raise RuntimeError(f"stream slots did not come back: {response[:40]!r}")
                    time.sleep(0.1)

            if stop(server) != 0:
                raise RuntimeError(f"server shutdown returned {server.returncode}")
        finally:
            for client in stalled:
                client.close()
            if server.poll() is None:
                stop(server)
        stderr.seek(0)
        log = stderr.read().decode(errors="replace")
        if rejected and WARNING not in log:
            raise RuntimeError(f"no warning for the 503 answers: {log[-500:]!r}")


def check_zero_rejected(executable):
    result = subprocess.run([executable], capture_output=True, text=True, timeout=30)
    if result.returncode == 0:
        raise RuntimeError("a zero stream limit did not stop startup")
    if "Server.Limits.maximum_streams must be at least 1" not in result.stderr:
        raise RuntimeError(f"missing startup diagnostic: {result.stderr!r}")
    if result.stdout.strip():
        raise RuntimeError(f"a port was published: {result.stdout!r}")


def check_written_body_watch(executable):
    """While a handler writing its body waits: the host writes the
    keep-alive bytes when the body is quiet, a client that goes stops the
    handler at its wait, so its stream's place comes back at once rather
    than after the 10 s sleep, and a connection whose body had to wait to
    be written is read again (on Linux its registration was lost)."""
    server = subprocess.Popen([executable], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              text=True, start_new_session=True)
    try:
        port = read_port(server)
        ready_workers(server)
        with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
            client.sendall(b"GET /sleepy HTTP/1.1\r\nHost: x\r\n\r\n")
            data = bytearray()
            deadline = time.monotonic() + 1.5
            while data.count(b":\n") < 3:
                if time.monotonic() >= deadline:
                    raise RuntimeError(f"keep-alive bytes: {bytes(data)!r}")
                data.extend(client.recv(4096))
        started = time.monotonic()
        while not request(port, "GET", "/short").startswith(b"HTTP/1.1 200 "):
            if time.monotonic() - started >= 1:
                raise RuntimeError("the stream's place did not come back when its client went")
            time.sleep(0.01)

        with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
            client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            client.sendall(b"GET /short HTTP/1.1\r\nHost: x\r\n\r\n")
            time.sleep(0.3)
            data = bytearray()
            while not data.endswith(b"0\r\n\r\n"):
                data.extend(client.recv(65536))
            client.sendall(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
            if not read_head(client).startswith(b"HTTP/1.1 200 "):
                raise RuntimeError("the connection was not read again after its body waited")
        if stop(server) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
    finally:
        if server.poll() is None:
            server.kill()
            server.wait(timeout=6)


def check_waiting_limit(executable):
    # Limit 1: 0 live streams is immediately below the boundary, 1 is at
    # it, and accepting a second would exceed it. The gate fixes the fiber
    # interleaving instead of relying on a sleep to create the race.
    with socket.create_server(("127.0.0.1", 0)) as gate, tempfile.TemporaryDirectory() as directory, tempfile.TemporaryFile() as stderr:
        gate.settimeout(10)
        config = pathlib.Path(directory) / "config"
        config.mkdir()
        (config / "local.toml").write_text(f"port = {gate.getsockname()[1]}\n")
        server = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE,
                                  stderr=stderr, text=True, start_new_session=True)
        clients, peers = [], []
        try:
            port = read_port(server)

            def waiting_request():
                client = socket.create_connection(("127.0.0.1", port), timeout=10)
                client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
                client.sendall(b"GET /wait HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
                clients.append(client)
                peer, _ = gate.accept()
                peers.append(peer)
                return client, peer

            first, a = waiting_request()
            second, b = waiting_request()
            a.sendall(b"x")
            b.sendall(b"x")
            statuses = [read_head(client).split(b" ", 2)[1] for client in (first, second)]
            if sorted(statuses) != [b"200", b"503"]:
                raise RuntimeError(f"stream limit after suspension: {statuses}")

            # Start at the full limit, then free the slot while the new
            # handler waits. Its acceptance must use the current count.
            third, c = waiting_request()
            first.close()
            second.close()
            deadline = time.monotonic() + 5
            while not request(port, "GET", "/short").startswith(b"HTTP/1.1 200 "):
                if time.monotonic() >= deadline:
                    raise RuntimeError("stream slot was not released")
                time.sleep(0.01)
            c.sendall(b"x")
            if not read_head(third).startswith(b"HTTP/1.1 200 "):
                raise RuntimeError("a stream was rejected using the count before suspension")
            third.close()

            # A client that goes while the body waits for the gate:
            # the handler stops there, its gate connection closes, and the
            # stream's place comes back. The third stream gives its place
            # back once it sees its client gone, which may be after this.
            deadline = time.monotonic() + 5
            while not request(port, "GET", "/short").startswith(b"HTTP/1.1 200 "):
                if time.monotonic() >= deadline:
                    raise RuntimeError("the third stream's place did not come back")
                time.sleep(0.01)
            client = socket.create_connection(("127.0.0.1", port), timeout=10)
            clients.append(client)
            client.sendall(b"GET /gate-stream HTTP/1.1\r\nHost: x\r\n\r\n")
            if not read_head(client).startswith(b"HTTP/1.1 200 "):
                raise RuntimeError("the gate stream did not start")
            peer, _ = gate.accept()
            peers.append(peer)
            client.close()
            peer.settimeout(2)
            if peer.recv(1) != b"":
                raise RuntimeError("the gate connection stayed open after the client went")
            deadline = time.monotonic() + 1
            while not request(port, "GET", "/short").startswith(b"HTTP/1.1 200 "):
                if time.monotonic() >= deadline:
                    raise RuntimeError("the stream's place did not come back when its client went")
                time.sleep(0.01)
        finally:
            for client in clients + peers:
                client.close()
            stop(server)


def main():
    check_limit(sys.argv[1])
    check_written_body_watch(sys.argv[1])
    check_zero_rejected(sys.argv[2])
    check_waiting_limit(sys.argv[3])


if __name__ == "__main__":
    main()
