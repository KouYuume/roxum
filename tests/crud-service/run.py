#!/usr/bin/env python3
"""M20d: the first goal end to end. The layered sample, with PostgreSQL and
the tax-rate service, in every backend:

- the typed routes create, update, and delete a product
- /metrics counts requests by route with their latency, the host's own
  refusals (a malformed request), the outbound pools of the database and the
  tax service, each worker's gauges, and a worker's restart after SIGKILL
- under load, with calls to the tax service in flight, SIGTERM fails no
  request sent before it, answers none with 5xx, and exits 0
"""
import http.client
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "support"))
sys.path.insert(0, str(ROOT / "tests" / "layered-app" / "fixture"))
sys.path.insert(0, str(ROOT / "tests" / "layered-app"))
import postgres_server  # noqa: E402
import run as layered  # noqa: E402  (tests/layered-app/run.py)
from roxum_process import children  # noqa: E402
from tax_service import TaxService  # noqa: E402

CLIENTS = 8
QUOTE = "/products/tea/quote/1"
QUOTE_ROUTE = "/products/{sku}/quote/{quantity}"
# Requests sent this long before SIGTERM must succeed; one sent closer may
# still be in the kernel's buffer when the drain closes idle connections.
MARGIN_SECONDS = 0.05


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


SAMPLE = re.compile(r'([a-z_]+)(?:\{(.*)\})? (\S+)')
LABEL = re.compile(r'([a-z_]+)="((?:[^"\\]|\\.)*)"')


def scrape(port):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        connection.request("GET", "/metrics")
        response = connection.getresponse()
        assert response.status == 200, response.status
        body = response.read().decode()
    finally:
        connection.close()
    samples = {}
    for line in body.splitlines():
        if line.startswith("#"):
            continue
        match = SAMPLE.fullmatch(line)
        assert match is not None, line
        samples[(match.group(1), tuple(LABEL.findall(match.group(2) or "")))] = float(match.group(3))
    return samples


def requests_total(route, method, status, outcome="handled"):
    return ("roxum_http_requests_total", (("route", route), ("method", method), ("status", status), ("outcome", outcome)))


def wait_for(condition, label, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {label}")


def ready(port):
    try:
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        connection.request("GET", "/ready")
        return connection.getresponse().status == 200
    except OSError:
        return False


def wait_between_responses(clients, delay_seconds):
    """Every quote waits on the tax service, so the clients' responses come
    together, one burst per delay. A scrape in a burst finds a request counted in
    one series and not yet in the next, and a signal after one finds none in
    flight, so wait for the middle of the delay."""
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        latest = max(result[1] for client in clients for result in client.results)
        if time.monotonic() - latest >= delay_seconds / 2:
            return
        time.sleep(0.005)
    raise AssertionError("the responses did not come together")


class Client(threading.Thread):
    """Sends quotes on one keep-alive connection until it closes, noting
    when each was sent, when it finished, and how."""

    def __init__(self, port, stop):
        super().__init__(daemon=True)
        self.port = port
        self.stop = stop
        self.results = []

    def run(self):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=30)
        while not self.stop.is_set():
            sent = time.monotonic()
            try:
                connection.request("GET", QUOTE)
                response = connection.getresponse()
                response.read()
                self.results.append((sent, time.monotonic(), response.status))
                if response.getheader("Connection") == "close":
                    return
            except (OSError, http.client.HTTPException) as error:
                self.results.append((sent, time.monotonic(), type(error).__name__))
                return


def start(executable, directory, local_text):
    """Starts the server with its stderr in a file: a pipe nobody reads
    would fill, and the app's `Log` would then hold the worker."""
    config = Path(directory) / "config"
    config.mkdir(exist_ok=True)
    (config / "local.toml").write_text(local_text)
    stderr = tempfile.TemporaryFile()
    server = subprocess.Popen([str(executable)], cwd=directory, stdout=subprocess.PIPE, stderr=stderr, text=True,
                              start_new_session=True)
    return server, stderr


def finish(server, stderr):
    """Stops the server if it still runs and returns its stderr."""
    if server.poll() is None:
        os.killpg(server.pid, signal.SIGKILL)
        server.wait(timeout=10)
    stderr.seek(0)
    text = stderr.read().decode(errors="replace")
    stderr.close()
    return text


def verify_crud(port, opt):
    sku = f"svc-{opt}"
    body = '{"sku": "%s", "name": "Teapot", "price_cents": 3000}' % sku
    assert layered.send(port, "POST", "/products", body)[:2] == (201, f"{sku}: Teapot (3000 cents)\n")
    change = '{"name": "Iron teapot", "price_cents": 4200}'
    assert layered.send(port, "PUT", f"/products/{sku}", change)[:2] == (200, f"{sku}: Iron teapot (4200 cents)\n")
    assert layered.send(port, "GET", f"/products/{sku}")[:2] == (200, f"{sku}: Iron teapot (4200 cents)\n")
    assert layered.send(port, "DELETE", f"/products/{sku}")[:2] == (204, "")


def verify(executable, directory, opt, database, tax):
    metrics_port = free_port()
    local = layered.LOCAL.replace("[listen]\n", f"[listen]\nmetrics_port = {metrics_port}\n", 1)
    server, stderr = start(executable, directory, local)
    try:
        port = layered.read_port(server, opt)
        verify_crud(port, opt)

        # The host refuses a malformed request without running the app.
        with socket.create_connection(("127.0.0.1", port), timeout=10) as client:
            client.sendall(b"BAD\r\n\r\n")
            assert client.makefile("rb").readline().split(b" ")[1] == b"400"

        # The worker process (one, with two threads) killed with SIGKILL is
        # restarted and counted.
        os.kill(children(server.pid)[0], signal.SIGKILL)
        wait_for(lambda: scrape(metrics_port).get(("roxum_worker_restarts_total", ())) == 1, "the restart")
        wait_for(lambda: len(children(server.pid)) == 1 and ready(metrics_port), "the restarted worker")

        # Load, with every quote waiting on the tax service, then SIGTERM.
        tax.delay_seconds = 0.3
        stop = threading.Event()
        clients = [Client(port, stop) for _ in range(CLIENTS)]
        for client in clients:
            client.start()
        time.sleep(1.0)
        wait_between_responses(clients, tax.delay_seconds)
        samples = scrape(metrics_port)
        terminated_at = time.monotonic()
        os.kill(server.pid, signal.SIGTERM)
        stop.set()
        for client in clients:
            client.join(timeout=30)
        status = server.wait(timeout=30)
    finally:
        tax.delay_seconds = 0
        logs = finish(server, stderr)

    assert status == 0, (opt, status, logs)
    results = [result for client in clients for result in client.results]
    before = [result for result in results if result[0] < terminated_at - MARGIN_SECONDS]
    failed = [result for result in before if result[2] != 200]
    assert before and not failed, (opt, failed, logs)
    in_flight = [result for result in before if result[1] > terminated_at]
    assert in_flight, (opt, "no request was in flight at SIGTERM", logs)
    server_errors = [result for result in results if isinstance(result[2], int) and result[2] >= 500]
    assert not server_errors, (opt, server_errors, logs)

    expected = {
        requests_total("/products", "POST", "201"): 1,
        requests_total("/products/{sku}", "PUT", "200"): 1,
        requests_total("/products/{sku}", "GET", "200"): 1,
        requests_total("/products/{sku}", "DELETE", "204"): 1,
        requests_total("", "", "400", "bad_request"): 1,
        ("roxum_worker_restarts_total", ()): 1,
    }
    for key, value in expected.items():
        assert samples.get(key) == value, (opt, key, samples.get(key))
    quotes = samples.get(requests_total(QUOTE_ROUTE, "GET", "200"), 0)
    assert quotes > 0, (opt, "no quote counted")
    assert samples.get(("roxum_http_request_duration_seconds_count", (("route", QUOTE_ROUTE),))) == quotes, opt
    for origin in (f"127.0.0.1:{tax.port}", f"127.0.0.1:{database.port}"):
        assert samples.get(("roxum_tcp_pool_wait_seconds_count", (("origin", origin),)), 0) > 0, (opt, origin)
    # One worker process: its gauges add up its threads.
    assert ("roxum_requests_in_progress", (("worker", "0"),)) in samples, opt
    assert ("roxum_requests_in_progress", (("worker", "1"),)) not in samples, opt
    print(f"{opt}: CRUD, metrics, a restart, and SIGTERM under load "
          f"({len(before)} requests, {len(in_flight)} in flight): PASS")


def main(opt, executable):
    """One backend's run (tools/check.py builds the executable), against a
    throwaway PostgreSQL and tax service of its own."""
    with tempfile.TemporaryDirectory(prefix="roxum-crud-service-") as temporary:
        os.chmod(temporary, 0o755)
        certificates = Path(temporary) / "certificates"
        certificates.mkdir()
        postgres_server.make_certificates(certificates)
        password_file = Path(temporary) / "database-password"
        password_file.write_text(postgres_server.APP_PASSWORD + "\n")
        token_file = Path(temporary) / "tax-token"
        token_file.write_text(layered.TAX_TOKEN + "\n")
        database = postgres_server.start(certificates)
        tax = TaxService(layered.TAX_TOKEN).start()
        layered.LOCAL = layered.local_settings(database.port, password_file, tax.port, token_file)
        try:
            directory = Path(temporary) / f"run-{opt}"
            directory.mkdir()
            verify(Path(executable), directory, opt, database, tax)
        finally:
            tax.stop()
            database.stop()


if __name__ == "__main__":
    main(*sys.argv[1:3])
