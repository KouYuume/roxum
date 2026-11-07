#!/usr/bin/env python3
"""Tcp: outbound connections from Roc handlers, through host pools.

One worker serves every request, so requests that wait for a server
overlap only through fibers. The test runs a line server (plain and TLS)
and checks waiting, pool reuse and limits, timeouts, closes, `discard!`,
TLS, name resolution, `write_derived!`, and that every request frees its
memory.
"""
import os
import pathlib
import re
import socket
import ssl
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, stop  # noqa: E402

SECRET = "tcp-secret-5e1d0a"
SLOW_SECONDS = 0.3


class LineServer:
    """`PING` -> `PONG`, `SLOW` -> `DONE` after 300 ms, `HANG` -> nothing,
    `CLOSE` closes, `SECRET <value>` -> `GOT SECRET`, others echo."""

    def __init__(self, context=None, later_context=None):
        self.listener = socket.create_server(("127.0.0.1", 0))
        # `STARTTLS` gets `GO`, then the connection switches to TLS.
        self.later_context = later_context
        self.port = self.listener.getsockname()[1]
        self.context = context
        self.lock = threading.Lock()
        self.accepts = 0
        self.active = 0
        self.max_active = 0
        self.closes = 0
        self.secrets = []
        self.connections = set()
        threading.Thread(target=self.accept_loop, daemon=True).start()

    def accept_loop(self):
        while True:
            try:
                client, _ = self.listener.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(client,), daemon=True).start()

    def serve(self, client):
        if self.context is not None:
            try:
                client = self.context.wrap_socket(client, server_side=True)
            except (ssl.SSLError, OSError):
                client.close()
                return
        with self.lock:
            self.accepts += 1
            self.active += 1
            self.max_active = max(self.max_active, self.active)
            self.connections.add(client)
        try:
            pending = b""
            while True:
                data = client.recv(4096)
                if not data:
                    break
                pending += data
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    if line == b"STARTTLS" and self.later_context is not None:
                        client.sendall(b"GO\n")
                        with self.lock:
                            self.connections.discard(client)
                        client = self.later_context.wrap_socket(client, server_side=True)
                        with self.lock:
                            self.connections.add(client)
                        continue
                    if not self.answer(client, line.decode()):
                        return
        except OSError:
            pass
        finally:
            with self.lock:
                self.active -= 1
                self.closes += 1
                self.connections.discard(client)
            try:
                client.close()
            except OSError:
                pass

    def answer(self, client, line):
        if line == "PING":
            client.sendall(b"PONG\n")
        elif line == "SLOW":
            time.sleep(SLOW_SECONDS)
            client.sendall(b"DONE\n")
        elif line == "HANG":
            pass
        elif line == "CLOSE":
            return False
        elif line.startswith("SECRET "):
            with self.lock:
                self.secrets.append(line[len("SECRET "):])
            client.sendall(b"GOT SECRET\n")
        else:
            client.sendall(f"ECHO {line}\n".encode())
        return True

    def counts(self):
        with self.lock:
            return self.accepts, self.closes

    def reset_max(self):
        with self.lock:
            self.max_active = self.active

    def close_idle(self):
        """Closes every open connection, as a server does to idle ones."""
        with self.lock:
            connections = list(self.connections)
        for connection in connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def get(port, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=30) as response:
        return response.read().decode().strip()


def run_all(calls):
    results = [None] * len(calls)

    def call(index):
        results[index] = calls[index]()

    threads = [threading.Thread(target=call, args=(index,)) for index in range(len(calls))]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    return results


def check(label, actual, expected):
    if actual != expected:
        raise RuntimeError(f"{label}: expected {expected!r}, got {actual!r}")


def wait_for(condition, label):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.02)
    raise RuntimeError(f"timed out waiting for {label}")


def main(executable, certificates, contract_alloc):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificates / "server.pem", certificates / "server.key")
    echo = LineServer(later_context=context)
    secure = LineServer(context)
    closed = socket.create_server(("127.0.0.1", 0))
    closed_port = closed.getsockname()[1]
    closed.close()

    with tempfile.TemporaryDirectory() as directory:
        config = pathlib.Path(directory) / "config"
        config.mkdir()
        (config / "local.toml").write_text(
            f"echo_port = {echo.port}\ntls_port = {secure.port}\nclosed_port = {closed_port}\n"
            f"ca_file = \"{certificates / 'ca.pem'}\"\n")
        environment = {**os.environ, "ROXUM_TEST_SECRET": SECRET}
        requests = 0
        with tempfile.TemporaryFile() as stderr:
            server = subprocess.Popen([executable], cwd=directory, env=environment, stdout=subprocess.PIPE,
                                      stderr=stderr, text=True, start_new_session=True)
            try:
                port = read_port(server)

                # A new connection, then the same one again.
                check("first", get(port, "/new"), "new")
                check("second", get(port, "/new"), "reused")
                # The echo server counts a connection on its own thread, after
                # the app may already have answered: wait for the one connection.
                wait_for(lambda: echo.counts()[0] == 1, "the echo server to count the first connection")
                accepts, _ = echo.counts()
                for _ in range(10):
                    check("ping", get(port, "/line/plain/PING"), "PONG")
                check("reuse", echo.counts()[0], accepts)
                requests += 12

                # Requests waiting for the server do not hold the worker.
                echo.reset_max()
                probes = []
                done = threading.Event()

                def probe():
                    while not done.is_set():
                        started = time.monotonic()
                        check("fast", get(port, "/fast"), "fast")
                        probes.append(time.monotonic() - started)
                        time.sleep(0.01)

                prober = threading.Thread(target=probe)
                prober.start()
                started = time.monotonic()
                slow = run_all([lambda: get(port, "/line/plain/SLOW")] * 32)
                elapsed = time.monotonic() - started
                done.set()
                prober.join()
                requests += 32 + len(probes)
                check("slow", slow, ["DONE"] * 32)
                # One at a time would take 32 * 0.3 s.
                if elapsed > 32 * SLOW_SECONDS / 4:
                    raise RuntimeError(f"32 waiting requests took {elapsed:.2f} s")
                if statistics.median(probes) > 0.05:
                    raise RuntimeError(f"quick requests waited: median {statistics.median(probes) * 1000:.1f} ms")
                if echo.max_active > 32:
                    raise RuntimeError(f"the pool opened {echo.max_active} connections at once")

                # A full pool: one request gets the connection, the others give
                # up after the 100 ms acquire timeout.
                echo.reset_max()
                busy = run_all([lambda: get(port, "/line/single/SLOW")] * 3)
                requests += 3
                check("busy", sorted(busy), ["DONE", "TcpBusy", "TcpBusy"])

                # Failed reads close the connection; errors of the client's own
                # do not.
                _, closes = echo.counts()
                check("hang", get(port, "/line/plain/HANG"), "TcpTimedOut")
                wait_for(lambda: echo.counts()[1] > closes, "the timed-out connection to close")
                check("close", get(port, "/line/plain/CLOSE"), "TcpClosed")
                _, closes = echo.counts()
                check("discard", get(port, "/discard"), "PONG")
                wait_for(lambda: echo.counts()[1] > closes, "the discarded connection to close")
                accepts, closes = echo.counts()
                check("client error", get(port, "/fail-after-ping"), "ClientRefused")
                check("after client error", get(port, "/line/single/PING"), "PONG")
                check("client error keeps the connection", echo.counts(), (accepts + 1, closes))
                requests += 5

                # A crash with the connection lent answers 500 and closes the
                # connection; the pool of one lends again.
                _, closes = echo.counts()
                try:
                    get(port, "/crash-in-with")
                except urllib.error.HTTPError as error:
                    check("crash in with", error.code, 500)
                else:
                    raise RuntimeError("crash in with: no 500")
                wait_for(lambda: echo.counts()[1] > closes, "the crashed request's connection to close")
                check("after crash", get(port, "/line/single/PING"), "PONG")
                requests += 1

                # Connections the server closed while idle are replaced.
                echo.close_idle()
                wait_for(lambda: echo.active == 0, "the server to close idle connections")
                accepts, _ = echo.counts()
                check("after idle close", get(port, "/line/plain/PING"), "PONG")
                check("replaced", echo.counts()[0], accepts + 1)
                requests += 1

                check("tls", get(port, "/line/tls/PING"), "PONG")
                check("tls reuse", get(port, "/line/tls/hello"), "ECHO hello")
                check("start tls", get(port, "/start-tls"), "PONG")
                check("start tls reuse", get(port, "/start-tls"), "PONG")
                check("untrusted", get(port, "/line/untrusted/PING"), "TcpTlsFailed")
                check("unresolvable", get(port, "/line/unresolvable/PING"), "TcpResolveFailed")
                check("refused", get(port, "/line/refused/PING"), "TcpConnectFailed")
                check("secret", get(port, "/secret"), "GOT SECRET")
                check("secret received", echo.secrets, [SECRET])
                requests += 8
            finally:
                stop(server)
            stderr.seek(0)
            log = stderr.read().decode(errors="replace")
        if SECRET in log:
            raise RuntimeError("the secret appeared in the server's output")
        crashes = [line for line in log.splitlines() if line.startswith("Roc crashed: ")]
        # The host names the crashed request by the ID it generated.
        normalized = [re.sub(r"request_id=[0-9a-f]{32}", "request_id=ID", re.sub(r"pid=\d+", "pid=N", line))
                      for line in crashes]
        check("crash log", normalized, ["Roc crashed: pid=N GET /crash-in-with request_id=ID: tcp test crash"])
        other = [line for line in log.splitlines() if "roxum-contract-request-ok" not in line and line not in crashes]
        if other:
            raise RuntimeError("unexpected stderr:\n" + "\n".join(other[:20]))
        if contract_alloc and log.count("roxum-contract-request-ok") != requests:
            raise RuntimeError(f"expected {requests} contract markers, found {log.count('roxum-contract-request-ok')}")
        print(f"32 waiting requests in {elapsed:.3f} s; quick requests median {statistics.median(probes) * 1000:.1f} ms")


if __name__ == "__main__":
    main(sys.argv[1], pathlib.Path(sys.argv[2]), os.environ.get("ROXUM_CONTRACT_ALLOC") == "1")
