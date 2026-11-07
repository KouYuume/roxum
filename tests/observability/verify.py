#!/usr/bin/env python3
"""M20a, M20b, M20c: the access log, the metrics, and the admin port.

Each response writes one JSON line on stderr, the ones the host answers
without running the app included:

- the app's answers name their route pattern (a nested one in full, the
  custom fallback as `fallback`), status, body bytes (none for HEAD, every
  chunk of a stream), and queue wait
- a 405, a malformed request (400), a crash (500), and a request refused
  after waiting past the queue timeout (503) name their outcome
- the path is written without its query, only with `JsonLinesWithPath`
- a draining worker writes every queued line before it exits
- `Off` writes none

With `Server.Metrics.Listen`, the supervisor answers `/live`, `/ready`, and
`/metrics` on the admin port:

- every response is counted by route, method, status, and outcome, with its
  duration, body bytes, and queue wait; an outbound pool's waits and leases
  are counted by origin; the worker's gauges are labeled by worker
- a worker killed with SIGKILL is counted as restarted, and the counts it
  made survive it
- `/ready` answers 503 while the server drains
- with `Server.Metrics.Off`, no admin port listens
"""
import http.client
import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import children, read_port, stop  # noqa: E402

MARKER = "roxum-contract-request-ok"
TIME = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z")
GENERATED_ID = re.compile(r"[0-9a-f]{32}")
FIELDS = ["time", "method", "route", "path", "status", "outcome", "body_bytes", "duration_us", "queue_us", "pid",
          "request_id"]


def check(label, actual, expected):
    if actual != expected:
        raise RuntimeError(f"{label}: expected {expected!r}, got {actual!r}")


class DelayServer:
    """Answers a line `N` with `done` after N milliseconds."""

    def __init__(self):
        self.listener = socket.create_server(("127.0.0.1", 0), backlog=16)
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


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class Server:
    def __init__(self, executable, directory, access_log, queue_timeout_milliseconds=5000, metrics_port=0,
                 delay_port=1):
        config = pathlib.Path(directory) / "config"
        config.mkdir(exist_ok=True)
        (config / "local.toml").write_text(
            f'access_log = "{access_log}"\nqueue_timeout_milliseconds = {queue_timeout_milliseconds}\n'
            f'metrics_port = {metrics_port}\ndelay_port = {delay_port}\n')
        self.stderr = tempfile.TemporaryFile()
        self.process = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE, stderr=self.stderr,
                                        text=True, start_new_session=True)
        self.port = read_port(self.process)

    def request(self, method, path):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        try:
            connection.request(method, path)
            response = connection.getresponse()
            return response.status, response.read()
        finally:
            connection.close()

    def raw(self, data):
        """Sends bytes as they are and returns the status line."""
        with socket.create_connection(("127.0.0.1", self.port), timeout=10) as client:
            client.sendall(data)
            return client.makefile("rb").readline()

    def finish(self, signaled=False):
        """Stops the server with SIGTERM, or waits for it when the test sent
        one (a second would stop it at once), and returns its access log
        lines, parsed, and the other lines of its stderr."""
        status = self.process.wait(timeout=15) if signaled else stop(self.process, timeout=15)
        self.stderr.seek(0)
        text = self.stderr.read().decode(errors="replace").splitlines()
        self.stderr.close()
        check("exit status", status, 0)
        lines, other = [], []
        for line in text:
            if line.startswith("{"):
                lines.append(json.loads(line))
            elif line != MARKER:
                other.append(line)
        for line in lines:
            check("field order", list(line), [field for field in FIELDS if field in line])
            if TIME.fullmatch(line["time"]) is None:
                raise RuntimeError(f"time is not RFC 3339 in UTC: {line!r}")
            if GENERATED_ID.fullmatch(line["request_id"]) is None:
                raise RuntimeError(f"request_id is not a generated ID: {line!r}")
            if not isinstance(line["duration_us"], int) or line["duration_us"] < 0:
                raise RuntimeError(f"duration_us is not a count of microseconds: {line!r}")
            check("pid", line["pid"], self.worker_pid(lines))
        return lines, other

    @staticmethod
    def worker_pid(lines):
        return lines[0]["pid"]


def summary(line):
    """The fields a case decides, without the ones that vary by run."""
    return {key: value for key, value in line.items() if key not in ("time", "duration_us", "pid", "request_id")}


def with_path(executable, directory):
    server = Server(executable, directory, "json_lines_with_path", queue_timeout_milliseconds=200)
    check("route", server.request("GET", "/users/42?token=secret"), (200, b"user\n"))
    check("HEAD", server.request("HEAD", "/users/42"), (200, b""))
    check("nested route", server.request("GET", "/api/acme/items/7"), (200, b"item\n"))
    check("error reply", server.request("GET", "/teapot"), (418, b"teapot\n"))
    check("fallback", server.request("GET", "/nowhere"), (404, b"fallback\n"))
    check("405", server.request("POST", "/users/42")[0], 405)
    check("stream", server.request("GET", "/stream"), (200, b"abcabc"))
    check("crash", server.request("GET", "/crash")[0], 500)
    check("malformed", server.raw(b"BAD\r\n\r\n").split(b" ")[1], b"400")

    # Behind a request that holds the Roc thread for 1 s, a request queued
    # past the 200 ms queue timeout is answered 503 without running.
    busy_result = []
    busy = threading.Thread(target=lambda: busy_result.append(server.request("GET", "/busy/1000")))
    busy.start()
    time.sleep(0.2)
    check("queue timeout", server.request("GET", "/users/1?token=secret")[0], 503)
    busy.join(timeout=30)
    check("busy", busy_result, [(200, b"busy\n")])

    lines, other = server.finish()
    check("other stderr", [line for line in other if not line.startswith("Roc crashed: ")], [])

    def handled(method, route, path, status, body_bytes):
        return {"method": method, "route": route, "path": path, "status": status, "outcome": "handled",
                "body_bytes": body_bytes}

    expected = [
        handled("GET", "/users/{id}", "/users/42", 200, 5),
        handled("HEAD", "/users/{id}", "/users/42", 200, 0),
        handled("GET", "/api/{tenant}/items/{id}", "/api/acme/items/7", 200, 5),
        handled("GET", "/teapot", "/teapot", 418, 7),
        handled("GET", "fallback", "/nowhere", 404, 9),
        {"method": "POST", "path": "/users/42", "status": 405, "outcome": "handled", "body_bytes": 0},
        handled("GET", "/stream", "/stream", 200, 6),
        {"method": "GET", "path": "/crash", "status": 500, "outcome": "crashed", "body_bytes": 0},
        {"status": 400, "outcome": "bad_request", "body_bytes": 0},
        {"method": "GET", "path": "/users/1", "status": 503, "outcome": "queue_timeout", "body_bytes": 0},
        handled("GET", "/busy/{milliseconds}", "/busy/1000", 200, 5),
    ]
    # The queued request's line comes when the loop refuses it, before the
    # busy request ends; the rest come in the order they were sent.
    observed = [{key: value for key, value in summary(line).items() if key != "queue_us"} for line in lines]
    check("lines", observed, expected)

    # Every request the Roc thread took names its wait in the queue, the
    # malformed one too; the one the loop refused while it waited does not.
    for line in lines:
        check(f"queue_us of {summary(line)!r}", "queue_us" in line, line["outcome"] != "queue_timeout")
    if len({line["request_id"] for line in lines}) != len(lines):
        raise RuntimeError("request IDs were reused")


def without_path(executable, directory):
    server = Server(executable, directory, "json_lines")
    check("route", server.request("GET", "/users/42"), (200, b"user\n"))
    lines, other = server.finish()
    check("other stderr", other, [])
    check("lines", [summary(line) for line in lines],
          [{"method": "GET", "route": "/users/{id}", "status": 200, "outcome": "handled", "body_bytes": 5,
            "queue_us": lines[0].get("queue_us")}])
    if "queue_us" not in lines[0]:
        raise RuntimeError(f"queue_us missing: {lines[0]!r}")


def off(executable, directory):
    port = free_port()
    server = Server(executable, directory, "off")
    check("route", server.request("GET", "/users/42"), (200, b"user\n"))
    try:
        socket.create_connection(("127.0.0.1", port), timeout=2).close()
        raise RuntimeError("an admin port listens with Server.Metrics.Off")
    except ConnectionRefusedError:
        pass
    lines, other = server.finish()
    check("lines", lines, [])
    check("other stderr", other, [])


def admin(port, method, path):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        connection.request(method, path)
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


SAMPLE = re.compile(r'([a-z_]+)(?:\{(.*)\})? (\S+)')
LABEL = re.compile(r'([a-z_]+)="((?:[^"\\]|\\.)*)"')


def scrape(port):
    """The admin port's samples: {(name, ((label, value), ...)): value}."""
    status, body = admin(port, "GET", "/metrics")
    check("/metrics status", status, 200)
    samples = {}
    for line in body.decode().splitlines():
        if line.startswith("#"):
            continue
        match = SAMPLE.fullmatch(line)
        if match is None:
            raise RuntimeError(f"not a sample line: {line!r}")
        labels = tuple(LABEL.findall(match.group(2) or ""))
        samples[(match.group(1), labels)] = float(match.group(3))
    return samples


def requests_total(route, method, status, outcome="handled"):
    return ("roxum_http_requests_total", (("route", route), ("method", method), ("status", status), ("outcome", outcome)))


def wait_for(condition, label, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.05)
    raise RuntimeError(f"timed out waiting for {label}")


def metrics(executable, directory):
    delay = DelayServer()
    port = free_port()
    server = Server(executable, directory, "off", metrics_port=port, delay_port=delay.port)
    check("/live", admin(port, "GET", "/live"), (200, b"live\n"))
    check("HEAD /live", admin(port, "HEAD", "/live"), (200, b""))
    check("/ready", admin(port, "GET", "/ready"), (200, b"ready\n"))
    check("POST /live", admin(port, "POST", "/live")[0], 405)
    check("unknown admin path", admin(port, "GET", "/nowhere")[0], 404)

    for _ in range(2):
        check("route", server.request("GET", "/users/42"), (200, b"user\n"))
    check("HEAD", server.request("HEAD", "/users/42"), (200, b""))
    check("nested route", server.request("GET", "/api/acme/items/7"), (200, b"item\n"))
    check("error reply", server.request("GET", "/teapot"), (418, b"teapot\n"))
    check("fallback", server.request("GET", "/nowhere"), (404, b"fallback\n"))
    check("405", server.request("POST", "/users/42")[0], 405)
    check("outbound call", server.request("GET", "/wait/50"), (200, b"waited\n"))

    samples = scrape(port)
    expected = {
        requests_total("/users/{id}", "GET", "200"): 2,
        requests_total("/users/{id}", "HEAD", "200"): 1,
        requests_total("/api/{tenant}/items/{id}", "GET", "200"): 1,
        requests_total("/teapot", "GET", "418"): 1,
        requests_total("fallback", "GET", "404"): 1,
        requests_total("", "POST", "405"): 1,
        requests_total("/wait/{milliseconds}", "GET", "200"): 1,
        ("roxum_http_request_duration_seconds_count", (("route", "/users/{id}"),)): 3,
        ("roxum_http_request_duration_seconds_bucket", (("route", "/users/{id}"), ("le", "+Inf"))): 3,
        ("roxum_http_response_body_bytes_total", (("route", "/users/{id}"),)): 10,
        ("roxum_queue_wait_seconds_count", ()): 8,
        ("roxum_tcp_pool_wait_seconds_count", (("origin", f"127.0.0.1:{delay.port}"),)): 1,
        ("roxum_tcp_pool_hold_seconds_count", (("origin", f"127.0.0.1:{delay.port}"),)): 1,
        ("roxum_queued_requests", (("worker", "0"),)): 0,
        ("roxum_streams", (("worker", "0"),)): 0,
        ("roxum_worker_restarts_total", ()): 0,
        ("roxum_access_log_dropped_total", ()): 0,
        ("roxum_metrics_dropped_total", ()): 0,
    }
    for key, value in expected.items():
        check(f"sample {key!r}", samples.get(key), value)
    request_series = sorted(key for key in samples if key[0] == "roxum_http_requests_total")
    check("request series", request_series, sorted(key for key in expected if key[0] == "roxum_http_requests_total"))
    hold = samples[("roxum_tcp_pool_hold_seconds_sum", (("origin", f"127.0.0.1:{delay.port}"),))]
    if hold < 0.05:
        raise RuntimeError(f"the lease of the delayed call took {hold} s")
    for name in ["roxum_connections", "roxum_requests_in_progress", "roxum_request_memory_bytes"]:
        if (name, (("worker", "0"),)) not in samples:
            raise RuntimeError(f"no {name} for worker 0")

    # A worker killed with SIGKILL: the supervisor restarts it, counts the
    # restart, and keeps what the worker counted.
    [worker] = children(server.process.pid)
    os.kill(worker, 9)
    wait_for(lambda: scrape(port).get(("roxum_worker_restarts_total", ())) == 1, "the restart to be counted")
    wait_for(lambda: admin(port, "GET", "/ready")[0] == 200, "the restarted worker")
    check("route after the restart", server.request("GET", "/users/42"), (200, b"user\n"))
    check("count across the restart", scrape(port).get(requests_total("/users/{id}", "GET", "200")), 3)

    # While a request holds the drain open, `/ready` answers 503.
    busy_result = []
    busy = threading.Thread(target=lambda: busy_result.append(server.request("GET", "/busy/1000")))
    busy.start()
    time.sleep(0.2)
    os.kill(server.process.pid, 15)
    wait_for(lambda: admin(port, "GET", "/ready")[0] == 503, "/ready to answer 503 in the drain", timeout=5)
    busy.join(timeout=30)
    check("busy", busy_result, [(200, b"busy\n")])
    lines, other = server.finish(signaled=True)
    check("lines", lines, [])
    check("other stderr", other, [])


def main(executable):
    with tempfile.TemporaryDirectory(prefix="roxum-observability-") as directory:
        for case in [with_path, without_path, off, metrics]:
            case(executable, directory)
            print(f"  {case.__name__}: ok")


if __name__ == "__main__":
    main(sys.argv[1])
