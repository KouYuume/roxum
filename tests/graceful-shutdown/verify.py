#!/usr/bin/env python3
"""M18: stopping with a drain.

Each case starts the server with one worker, sends requests that are still
running, then signals the server: SIGTERM to the supervisor (Kubernetes,
Docker), SIGTERM to the whole process group (systemd's default), or SIGINT
to the group (Ctrl-C). The server must stop accepting at once, close idle
keep-alive connections, finish what is running with `Connection: close`,
and exit 0; past the drain timeout, or on a second signal, it cuts what is
left and exits 1.
"""
import http.client
import os
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port  # noqa: E402

import signal  # noqa: E402

CUT_MESSAGE = "connections were cut"
MARKER = "roxum-contract-request-ok"
CONTRACT_ALLOC = os.environ.get("ROXUM_CONTRACT_ALLOC") == "1"


class DelayServer:
    """Answers a line `N` with `done` after N milliseconds."""

    def __init__(self):
        self.listener = socket.create_server(("127.0.0.1", 0))
        self.port = self.listener.getsockname()[1]
        threading.Thread(target=self.accept_loop, daemon=True).start()

    def accept_loop(self):
        while True:
            try:
                client, _ = self.listener.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(client,), daemon=True).start()

    def serve(self, client):
        try:
            pending = b""
            while True:
                data = client.recv(1024)
                if not data:
                    return
                pending += data
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    time.sleep(int(line) / 1000)
                    client.sendall(b"done\n")
        except OSError:
            pass
        finally:
            client.close()


class Server:
    def __init__(self, executable, directory, delay_port, drain_timeout_milliseconds):
        config = pathlib.Path(directory) / "config"
        config.mkdir(exist_ok=True)
        (config / "local.toml").write_text(
            f"delay_port = {delay_port}\ndrain_timeout_milliseconds = {drain_timeout_milliseconds}\n")
        self.stderr = tempfile.TemporaryFile()
        self.process = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE, stderr=self.stderr,
                                        text=True, start_new_session=True)
        self.port = read_port(self.process)

    def signal(self, how):
        if how == "supervisor":
            os.kill(self.process.pid, signal.SIGTERM)
        elif how == "group":
            os.killpg(self.process.pid, signal.SIGTERM)
        else:
            os.killpg(self.process.pid, signal.SIGINT)

    def wait(self, timeout):
        try:
            return self.process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGKILL)
            self.process.wait(timeout=5)
            raise RuntimeError(f"the server did not exit within {timeout} s")

    def log(self):
        """The server's stderr without the allocator's per-request markers."""
        return "".join(line for line in self.raw_log().splitlines(keepends=True) if line.strip() != MARKER)

    def markers(self):
        return self.raw_log().splitlines().count(MARKER)

    def raw_log(self):
        self.stderr.seek(0)
        return self.stderr.read().decode(errors="replace")

    def close(self):
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGKILL)
            self.process.wait(timeout=5)
        self.stderr.close()


class Call:
    """A request on a connection of its own, run in a thread, recording the
    status, the Connection header, the body, or the error."""

    def __init__(self, port, path):
        self.result = None
        self.connection = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        self.connection.connect()
        self.thread = threading.Thread(target=self.run, args=(path,))
        self.thread.start()

    def run(self, path):
        try:
            self.connection.request("GET", path)
            response = self.connection.getresponse()
            body = response.read()
            self.result = (response.status, response.getheader("Connection"), body)
        except (OSError, http.client.HTTPException) as error:
            self.result = type(error).__name__
        finally:
            self.connection.close()

    def join(self):
        self.thread.join(timeout=30)
        return self.result


def check(label, actual, expected):
    if actual != expected:
        raise RuntimeError(f"{label}: expected {expected!r}, got {actual!r}")


def refuses_connections(port):
    try:
        socket.create_connection(("127.0.0.1", port), timeout=2).close()
    except OSError:
        return True
    return False


def wait_until(condition, label, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.01)
    raise RuntimeError(f"timed out waiting for {label}")


def idle_connection(port):
    """A keep-alive connection that has served one request and waits."""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    connection.request("GET", "/fast")
    response = connection.getresponse()
    check("idle connection's first response", (response.status, response.read()), (200, b"fast\n"))
    return connection


def closed_by_server(connection):
    connection.sock.settimeout(2)
    try:
        return connection.sock.recv(1) == b""
    except OSError:
        return True


def drains(executable, directory, delay, how):
    """In-flight requests finish with `Connection: close`, an idle
    keep-alive connection is closed, new connections are refused, exit 0."""
    server = Server(executable, directory, delay.port, 20_000)
    try:
        idle = idle_connection(server.port)
        waiting = [Call(server.port, "/wait/800") for _ in range(3)]
        time.sleep(0.2)
        started = time.monotonic()
        server.signal(how)
        wait_until(lambda: refuses_connections(server.port), "new connections to be refused")
        check(f"{how}: idle keep-alive connection closed", closed_by_server(idle), True)
        results = [call.join() for call in waiting]
        check(f"{how}: in-flight requests", results, [(200, "close", b"waited\n")] * 3)
        status = server.wait(10)
        elapsed = time.monotonic() - started
        check(f"{how}: exit status", status, 0)
        if elapsed > 3:
            raise RuntimeError(f"{how}: the drain took {elapsed:.2f} s for requests of 0.8 s")
        check(f"{how}: log", server.log(), "")
        # The idle connection's request and the three that finished during
        # the drain each released all their memory.
        if CONTRACT_ALLOC:
            check(f"{how}: allocator markers", server.markers(), 4)
    finally:
        server.close()


def times_out(executable, directory, delay, path):
    """A request still running at the drain timeout is cut, the log says
    so, and the exit status is 1."""
    server = Server(executable, directory, delay.port, 500)
    try:
        call = Call(server.port, path)
        time.sleep(0.2)
        started = time.monotonic()
        server.signal("supervisor")
        status = server.wait(10)
        elapsed = time.monotonic() - started
        check(f"{path}: exit status after the timeout", status, 1)
        check(f"{path}: the cut request", call.join() in ("RemoteDisconnected", "ConnectionResetError"), True)
        # The worker checks the timeout on its 250 ms tick.
        if not 0.5 <= elapsed < 1.5:
            raise RuntimeError(f"{path}: stopped {elapsed:.2f} s after the signal, with a 0.5 s drain timeout")
        log = server.log()
        if "the drain timeout passed; 1 " + CUT_MESSAGE not in log:
            raise RuntimeError(f"{path}: unexpected log {log!r}")
    finally:
        server.close()


def second_signal(executable, directory, delay):
    """A second signal during the drain stops at once, with exit 1."""
    server = Server(executable, directory, delay.port, 20_000)
    try:
        call = Call(server.port, "/wait/5000")
        time.sleep(0.2)
        server.signal("supervisor")
        time.sleep(0.3)
        started = time.monotonic()
        server.signal("supervisor")
        status = server.wait(10)
        elapsed = time.monotonic() - started
        check("second signal: exit status", status, 1)
        check("second signal: the cut request", call.join() in ("RemoteDisconnected", "ConnectionResetError"), True)
        if elapsed > 1:
            raise RuntimeError(f"the second signal took {elapsed:.2f} s to stop the server")
        if "a second termination signal arrived; 1 " + CUT_MESSAGE not in server.log():
            raise RuntimeError(f"second signal: unexpected log {server.log()!r}")
    finally:
        server.close()


def stream_finishes(executable, directory, delay):
    """A stream that is being written when the drain starts is finished,
    even for a client that reads slowly."""
    server = Server(executable, directory, delay.port, 20_000)
    try:
        connection = http.client.HTTPConnection("127.0.0.1", server.port, timeout=30)
        connection.request("GET", "/stream")
        response = connection.getresponse()
        first = response.read(64 * 1024)
        server.signal("supervisor")
        rest = b""
        while True:
            chunk = response.read(256 * 1024)
            if not chunk:
                break
            rest += chunk
            time.sleep(0.01)
        check("stream length", len(first) + len(rest), 256 * 64 * 1024)
        connection.close()
        check("stream: exit status", server.wait(10), 0)
    finally:
        server.close()


def events_end(executable, directory, delay):
    """Streams marked `ends_on_drain` end cleanly at their next wait, a
    sleep or an outbound call, as the drain starts; an unmarked
    download is still written whole, and the worker exits 0."""
    server = Server(executable, directory, delay.port, 20_000)
    try:
        events = []
        for path, first in (("/events", b"data: tick\n\n"), ("/events-waiting", b"data: waiting\n\n")):
            connection = http.client.HTTPConnection("127.0.0.1", server.port, timeout=10)
            connection.request("GET", path)
            response = connection.getresponse()
            check(f"{path}: status", response.status, 200)
            check(f"{path}: first event", response.read(len(first)), first)
            events.append((path, connection, response))
        download = http.client.HTTPConnection("127.0.0.1", server.port, timeout=30)
        download.request("GET", "/stream")
        downloaded = download.getresponse()
        first = downloaded.read(64 * 1024)
        started = time.monotonic()
        server.signal("supervisor")
        for path, connection, response in events:
            # The chunked body's end arrives: a cut body raises IncompleteRead.
            rest = response.read()
            elapsed = time.monotonic() - started
            if elapsed > 1:
                raise RuntimeError(f"{path}: ended {elapsed:.2f} s after the signal")
            if b"never" in rest:
                raise RuntimeError(f"{path}: the code after the wait ran: {rest!r}")
            connection.close()
        rest = b""
        while True:
            chunk = downloaded.read(256 * 1024)
            if not chunk:
                break
            rest += chunk
            time.sleep(0.01)
        check("download length", len(first) + len(rest), 256 * 64 * 1024)
        download.close()
        check("events: exit status", server.wait(10), 0)
        check("events: log", server.log(), "")
    finally:
        server.close()


def group_is_empty(group):
    """No process but a zombie is left in the group: a container's PID 1 may not reap."""
    listing = subprocess.run(["ps", "-A", "-o", "pgid=,stat="], capture_output=True, text=True, check=True).stdout
    return not any(fields[0] == str(group) and not fields[1].startswith("Z")
                   for fields in (line.split() for line in listing.splitlines()))


def supervisor_killed(executable, directory, delay):
    """A supervisor that is killed cannot ask for a drain, and a worker ignores
    SIGTERM. The worker drains by itself: what is running finishes, new connections
    are refused, and no process is left."""
    server = Server(executable, directory, delay.port, 20_000)
    group = server.process.pid
    try:
        waiting = Call(server.port, "/wait/800")
        time.sleep(0.2)
        os.kill(group, signal.SIGKILL)
        server.process.wait(timeout=5)
        wait_until(lambda: refuses_connections(server.port), "new connections to be refused")
        check("a request in flight", waiting.join(), (200, "close", b"waited\n"))
        wait_until(lambda: group_is_empty(group), "the worker to exit")
        if "the supervisor is gone" not in server.log():
            raise RuntimeError(f"no warning: {server.log()!r}")
    finally:
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass
        server.close()


def main(executable):
    delay = DelayServer()
    with tempfile.TemporaryDirectory() as directory:
        for how in ("supervisor", "group", "interrupt"):
            drains(executable, directory, delay, how)
            print(f"drain on {how} signal: PASS")
        times_out(executable, directory, delay, "/wait/5000")
        print("a waiting request past the drain timeout: PASS")
        times_out(executable, directory, delay, "/spin")
        print("a handler that never returns, past the drain timeout: PASS")
        second_signal(executable, directory, delay)
        print("a second signal: PASS")
        stream_finishes(executable, directory, delay)
        print("a stream in progress: PASS")
        events_end(executable, directory, delay)
        print("streams that end on a drain: PASS")
        supervisor_killed(executable, directory, delay)
        print("a supervisor that is killed: PASS")


if __name__ == "__main__":
    main(sys.argv[1])
