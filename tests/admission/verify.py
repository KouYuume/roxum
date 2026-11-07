#!/usr/bin/env python3
"""M19: admission. With one worker, requests past a limit get
`503 Service Unavailable` with `Retry-After` quickly instead of waiting:

- the queue for the Roc thread is full: new requests are refused
- a request waited in the queue past the queue timeout: refused without
  running, even while the Roc thread is still busy
- the requests in progress (waiting on fibers) reach their limit: new
  requests are refused

Once the overload passes, requests succeed again. A zero limit stops the
startup.
"""
import http.client
import os
import pathlib
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, stop  # noqa: E402

MARKER = "roxum-contract-request-ok"
# The loop leaves new connections to other workers for a 50 ms grace and
# checks on a 50 ms tick; the rest is scheduling slack.
QUICK_SECONDS = 0.25
# How long `/busy` computes in the cases whose last request must arrive
# while it runs. A loaded machine delays this client's own sleeps by up to
# a second; `sent_while_busy` stops a case that fell behind anyway.
BUSY_MILLISECONDS = 3000


class DelayServer:
    """Answers a line `N` with `done` after N milliseconds."""

    def __init__(self):
        self.listener = socket.create_server(("127.0.0.1", 0), backlog=128)
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


class Call:
    """A request on a connection of its own, in a thread: the status, the
    Retry-After header, the body, and how long it took."""

    def __init__(self, port, path):
        self.result = None
        self.sent = time.monotonic()
        self.thread = threading.Thread(target=self.run, args=(port, path))
        self.thread.start()

    def run(self, port, path):
        started = time.monotonic()
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        try:
            connection.request("GET", path)
            response = connection.getresponse()
            body = response.read()
            self.result = (response.status, response.getheader("Retry-After"), body, time.monotonic() - started)
        except (OSError, http.client.HTTPException) as error:
            self.result = (type(error).__name__, None, b"", time.monotonic() - started)
        finally:
            connection.close()

    def join(self):
        self.thread.join(timeout=30)
        return self.result


def check(label, actual, expected):
    if actual != expected:
        raise RuntimeError(f"{label}: expected {expected!r}, got {actual!r}")


def sent_while_busy(label, busy, call):
    """Stops a case whose request went out after the computation it must
    arrive behind could have ended: the client fell behind, so the case says
    nothing about the server."""
    late = call.sent - busy.sent
    if late >= BUSY_MILLISECONDS / 1000:
        raise RuntimeError(f"{label}: this client sent the request {late:.2f} s after the computation began, "
                           f"past its {BUSY_MILLISECONDS} ms; the machine is too loaded for the case")


def refused_quickly(label, result):
    status, retry_after, _, elapsed = result
    check(f"{label}: status and Retry-After", (status, retry_after), (503, "1"))
    if elapsed > QUICK_SECONDS:
        raise RuntimeError(f"{label}: the 503 took {elapsed * 1000:.0f} ms")
    return elapsed


# Every server a case started, so a failing case leaves none running.
STARTED = []


class Server:
    def __init__(self, executable, directory, delay_port, **limits):
        settings = {"threads": 1, "maximum_queued_requests": 1024, "queue_timeout_milliseconds": 5000,
                    "maximum_requests_in_progress": 1024, "maximum_connections": 4096, "request_memory_bytes": 0,
                    **limits}
        config = pathlib.Path(directory) / "config"
        config.mkdir(exist_ok=True)
        (config / "local.toml").write_text(f"delay_port = {delay_port}\n" +
                                           "".join(f"{key} = {value}\n" for key, value in settings.items()))
        self.stderr = tempfile.TemporaryFile()
        self.process = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE, stderr=self.stderr,
                                        text=True, start_new_session=True)
        STARTED.append(self.process)
        self.port = read_port(self.process)

    def finish(self):
        status = stop(self.process, timeout=15)
        self.stderr.seek(0)
        lines = self.stderr.read().decode(errors="replace").splitlines()
        self.stderr.close()
        check("exit status", status, 0)
        other = [line for line in lines if line != MARKER]
        check("log", other, [])


def queue_full(executable, directory, delay):
    """The queue holds 2: behind a busy request, a third queued request is
    refused at once, the queued two run once the Roc thread is free."""
    server = Server(executable, directory, delay.port, maximum_queued_requests=2)
    busy = Call(server.port, f"/busy/{BUSY_MILLISECONDS}")
    time.sleep(0.2)
    queued = [Call(server.port, "/fast") for _ in range(2)]
    time.sleep(0.2)
    refused = Call(server.port, "/fast")
    sent_while_busy("queue full", busy, refused)
    elapsed = refused_quickly("queue full", refused.join())
    check("busy request", busy.join()[:3], (200, None, b"busy\n"))
    check("queued requests", [call.join()[:3] for call in queued], [(200, None, b"fast\n")] * 2)
    check("after the overload", Call(server.port, "/fast").join()[:3], (200, None, b"fast\n"))
    server.finish()
    return elapsed


def queue_timeout(executable, directory, delay):
    """A request queued behind a long computation is refused once it has
    waited 300 ms, while the computation is still running."""
    server = Server(executable, directory, delay.port, queue_timeout_milliseconds=300)
    busy = Call(server.port, f"/busy/{BUSY_MILLISECONDS}")
    time.sleep(0.2)
    queued = Call(server.port, "/fast")
    # Refused 300 ms after it arrives, which must still be within the computation.
    late = queued.sent - busy.sent
    if late + 0.3 + QUICK_SECONDS >= BUSY_MILLISECONDS / 1000:
        raise RuntimeError(f"queue timeout: this client sent the request {late:.2f} s after the computation began, "
                           f"too late for its 300 ms wait to end within {BUSY_MILLISECONDS} ms; the machine is too loaded for the case")
    status, retry_after, _, elapsed = queued.join()
    check("queue timeout: status and Retry-After", (status, retry_after), (503, "1"))
    if not 0.3 <= elapsed < 0.3 + QUICK_SECONDS:
        raise RuntimeError(f"queue timeout: refused after {elapsed * 1000:.0f} ms for a 300 ms timeout")
    check("busy request", busy.join()[:3], (200, None, b"busy\n"))
    server.finish()
    return elapsed


def busy_thread_left_alone(executable, directory, delay):
    """With two threads, a computation holds one: requests go on on
    the other, and a request whose wait ends while the computation runs
    resumes there at once rather than after it."""
    server = Server(executable, directory, delay.port, threads=2)
    waiting = Call(server.port, "/wait/300")
    time.sleep(0.1)
    busy = Call(server.port, "/busy/1500")
    time.sleep(0.1)
    status, _, body, elapsed = Call(server.port, "/fast").join()
    check("fast beside a computation", (status, body), (200, b"fast\n"))
    if elapsed >= QUICK_SECONDS:
        raise RuntimeError(f"fast beside a computation: answered after {elapsed * 1000:.0f} ms")
    status, _, body, elapsed = waiting.join()
    check("waiting beside a computation", (status, body), (200, b"waited\n"))
    if elapsed >= 0.3 + QUICK_SECONDS:
        raise RuntimeError(f"waiting beside a computation: answered after {elapsed * 1000:.0f} ms for a 300 ms wait")
    check("busy request", busy.join()[:3], (200, None, b"busy\n"))
    server.finish()


def sleeping_requests(executable, directory, delay):
    """`Sleep` waits on the request's fiber: with one thread, eight
    one-second sleeps take about one second in all, not eight, and a request
    beside them is answered at once. `Sleep.until!` keeps its interval
    whatever the work between the waits takes."""
    server = Server(executable, directory, delay.port)
    started = time.monotonic()
    sleeping = [Call(server.port, "/sleep/1000") for _ in range(8)]
    # Starting them takes the interpreter a while.
    time.sleep(0.4)
    status, _, body, elapsed = Call(server.port, "/fast").join()
    check("fast beside sleeping requests", (status, body), (200, b"fast\n"))
    if elapsed >= QUICK_SECONDS:
        raise RuntimeError(f"fast beside sleeping requests: answered after {elapsed * 1000:.0f} ms")
    check("sleeping requests", [call.join()[:3] for call in sleeping], [(200, None, b"slept\n")] * 8)
    took = time.monotonic() - started
    if not 1.0 <= took < 2.0:
        raise RuntimeError(f"eight one-second sleeps on one thread took {took * 1000:.0f} ms")
    status, _, body, _ = Call(server.port, "/ticks/100").join()
    check("ticks: status", status, 200)
    if not 300 <= int(body) < 300 + QUICK_SECONDS * 1000:
        raise RuntimeError(f"three 100 ms ticks took {int(body)} ms")
    check("a sleep of 0", Call(server.port, "/sleep/0").join()[:3], (200, None, b"slept\n"))
    server.finish()


def all_threads_busy(executable, directory, delay):
    """With two threads both computing, a full queue is still refused at
    once: the acceptor reads the head in their place."""
    server = Server(executable, directory, delay.port, threads=2, maximum_queued_requests=1)
    # Apart, so a thread takes the first before the second would queue.
    busy = []
    for _ in range(2):
        busy.append(Call(server.port, f"/busy/{BUSY_MILLISECONDS}"))
        time.sleep(0.1)
    time.sleep(0.1)
    queued = Call(server.port, "/fast")
    time.sleep(0.2)
    refused = Call(server.port, "/fast")
    sent_while_busy("all threads busy", busy[0], refused)
    elapsed = refused_quickly("all threads busy", refused.join())
    check("busy requests", [call.join()[:3] for call in busy], [(200, None, b"busy\n")] * 2)
    check("queued request", queued.join()[:3], (200, None, b"fast\n"))
    server.finish()
    return elapsed


def in_progress_full(executable, directory, delay):
    """Three requests waiting on the delay server fill the limit of 3: a
    fourth is refused at once, and requests succeed once they finish."""
    server = Server(executable, directory, delay.port, maximum_requests_in_progress=3)
    waiting = [Call(server.port, "/wait/1000") for _ in range(3)]
    time.sleep(0.3)
    elapsed = refused_quickly("in progress full", Call(server.port, "/fast").join())
    check("waiting requests", [call.join()[:3] for call in waiting], [(200, None, b"waited\n")] * 3)
    check("after the overload", Call(server.port, "/fast").join()[:3], (200, None, b"fast\n"))
    server.finish()
    return elapsed


def memory_limit(executable, directory, delay):
    """With 4 MiB for requests: one holding 3.5 MiB while it waits is past
    the 80 % admission stage, so new requests are refused; one that holds
    5 MiB before it reads has its read refused with `TcpOverloaded`. Once
    the memory is released, requests succeed again."""
    server = Server(executable, directory, delay.port, request_memory_bytes=4 * 1024 * 1024)
    holding = Call(server.port, f"/hold/{3584}/1000")
    time.sleep(0.4)
    elapsed = refused_quickly("memory near the limit", Call(server.port, "/fast").join())
    check("holding request", holding.join()[:3], (200, None, f"held {3584 * 1024} 120\n".encode()))
    check("after the memory is released", Call(server.port, "/fast").join()[:3], (200, None, b"fast\n"))
    check("over the limit", Call(server.port, "/hold/5120/10").join()[:3], (200, None, b"TcpOverloaded\n"))
    check("after the refused read", Call(server.port, "/fast").join()[:3], (200, None, b"fast\n"))
    status = stop(server.process, timeout=15)
    server.stderr.seek(0)
    lines = [line for line in server.stderr.read().decode(errors="replace").splitlines() if line != MARKER]
    server.stderr.close()
    check("exit status", status, 0)
    if len(lines) != 1 or "over Server.Limits.request_memory (4194304); refusing reads" not in lines[0]:
        raise RuntimeError(f"memory limit: unexpected log {lines!r}")
    return elapsed


def connections_full(executable, directory, delay):
    """With room for 2 connections: when both are idle keep-alive
    connections, a third is served at once and the one idle longest is
    closed; when both are busy, a third waits until one finishes."""
    server = Server(executable, directory, delay.port, maximum_connections=2)
    held = []
    for _ in range(2):
        connection = http.client.HTTPConnection("127.0.0.1", server.port, timeout=10)
        connection.request("GET", "/fast")
        check("held connection", connection.getresponse().read(), b"fast\n")
        held.append(connection)
        time.sleep(0.1)
    status, _, body, elapsed = Call(server.port, "/fast").join()
    check("third connection", (status, body), (200, b"fast\n"))
    if elapsed > QUICK_SECONDS:
        raise RuntimeError(f"the third connection waited {elapsed * 1000:.0f} ms with idle connections to close")
    held[0].sock.settimeout(2)
    check("the longest-idle connection was closed", held[0].sock.recv(1), b"")
    held[1].request("GET", "/fast")
    check("the other idle connection still serves", held[1].getresponse().read(), b"fast\n")
    for connection in held:
        connection.close()

    busy = [Call(server.port, "/wait/1000") for _ in range(2)]
    time.sleep(0.3)
    status, _, body, elapsed = Call(server.port, "/fast").join()
    check("third connection while both are busy", (status, body), (200, b"fast\n"))
    if elapsed < 0.5:
        raise RuntimeError(f"the third connection was served after {elapsed * 1000:.0f} ms, before a busy one finished")
    check("busy requests", [call.join()[:3] for call in busy], [(200, None, b"waited\n")] * 2)
    server.finish()


def zero_refused(executable, directory, delay):
    config = pathlib.Path(directory) / "config"
    for text, message in (("maximum_connections = 65537", "Server.Limits.maximum_connections takes 1 to 65536"),
                          ("request_memory_bytes = 0\nmaximum_connections = 0", "Server.Limits.maximum_connections takes 1 to 65536"),
                          ("maximum_connections = 0", "Server.Limits.maximum_connections takes 1 to 65536")):
        (config / "local.toml").write_text(f"delay_port = {delay.port}\n{text}\n")
        result = subprocess.run([executable], cwd=directory, capture_output=True, text=True, timeout=30)
        if result.returncode == 0 or message not in result.stderr:
            raise RuntimeError(f"{text}: unexpected startup ({result.returncode}, {result.stderr!r})")
    for key in ("maximum_queued_requests", "queue_timeout_milliseconds", "maximum_requests_in_progress"):
        config = pathlib.Path(directory) / "config"
        (config / "local.toml").write_text(f"delay_port = {delay.port}\n{key} = 0\n")
        result = subprocess.run([executable], cwd=directory, capture_output=True, text=True, timeout=30)
        if result.returncode == 0 or result.stdout.strip():
            raise RuntimeError(f"{key} = 0: the server started")
        if f"Server.Limits.{key} must be at least 1" not in result.stderr:
            raise RuntimeError(f"{key} = 0: unexpected stderr {result.stderr!r}")


def main(executable):
    try:
        run_cases(executable)
    finally:
        for process in STARTED:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=6)


def run_cases(executable):
    delay = DelayServer()
    with tempfile.TemporaryDirectory() as directory:
        timings = [
            ("queue full", queue_full(executable, directory, delay)),
            ("queue timeout", queue_timeout(executable, directory, delay)),
            ("in progress full", in_progress_full(executable, directory, delay)),
            ("memory near the limit", memory_limit(executable, directory, delay)),
            ("all threads busy", all_threads_busy(executable, directory, delay)),
        ]
        busy_thread_left_alone(executable, directory, delay)
        sleeping_requests(executable, directory, delay)
        connections_full(executable, directory, delay)
        zero_refused(executable, directory, delay)
    print("; ".join(f"{label} 503 after {elapsed * 1000:.0f} ms" for label, elapsed in timings))


if __name__ == "__main__":
    main(sys.argv[1])
