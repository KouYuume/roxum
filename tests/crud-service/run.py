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
from concurrent.futures import ThreadPoolExecutor
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


def readiness_status(port):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        connection.request("GET", "/ready")
        return connection.getresponse().status
    except OSError:
        return None
    finally:
        connection.close()


def quote(connection):
    connection.request("GET", QUOTE)
    response = connection.getresponse()
    response.read()
    return response.status


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
        wait_for(lambda: len(children(server.pid)) == 1 and readiness_status(metrics_port) == 200, "the restarted worker")

        connections = [http.client.HTTPConnection("127.0.0.1", port, timeout=30) for _ in range(CLIENTS)]
        waiting_for_tax = threading.Barrier(CLIENTS + 1, timeout=15)
        release_tax = threading.Event()

        def hold_response():
            waiting_for_tax.wait()
            release_tax.wait()

        try:
            with ThreadPoolExecutor(max_workers=CLIENTS) as pool:
                assert list(pool.map(quote, connections)) == [200] * CLIENTS, opt
                # Keep the completed quote count fixed while /metrics reads
                # the request counter and the duration histogram separately.
                tax.before_response = hold_response
                pending = [pool.submit(quote, connection) for connection in connections]
                try:
                    waiting_for_tax.wait()
                    samples = scrape(metrics_port)
                    os.kill(server.pid, signal.SIGTERM)
                    wait_for(lambda: readiness_status(metrics_port) == 503, "the supervisor to start draining")
                finally:
                    release_tax.set()
                assert [request.result() for request in pending] == [200] * CLIENTS, opt
        finally:
            for connection in connections:
                connection.close()
        status = server.wait(timeout=30)
    finally:
        logs = finish(server, stderr)

    assert status == 0, (opt, status, logs)
    expected = {
        requests_total("/products", "POST", "201"): 1,
        requests_total("/products/{sku}", "PUT", "200"): 1,
        requests_total("/products/{sku}", "GET", "200"): 1,
        requests_total("/products/{sku}", "DELETE", "204"): 1,
        requests_total("", "", "400", "bad_request"): 1,
        ("roxum_worker_restarts_total", ()): 1,
        requests_total(QUOTE_ROUTE, "GET", "200"): CLIENTS,
        ("roxum_http_request_duration_seconds_count", (("route", QUOTE_ROUTE),)): CLIENTS,
    }
    for key, value in expected.items():
        assert samples.get(key) == value, (opt, key, samples.get(key), value)
    for origin in (f"127.0.0.1:{tax.port}", f"127.0.0.1:{database.port}"):
        assert samples.get(("roxum_tcp_pool_wait_seconds_count", (("origin", origin),)), 0) > 0, (opt, origin)
    # One worker process: its gauges add up its threads.
    assert ("roxum_requests_in_progress", (("worker", "0"),)) in samples, opt
    assert ("roxum_requests_in_progress", (("worker", "1"),)) not in samples, opt
    print(f"{opt}: CRUD, metrics, a restart, and SIGTERM under load "
          f"({CLIENTS} completed quotes, {CLIENTS} in flight): PASS")


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
