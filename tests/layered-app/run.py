#!/usr/bin/env python3
"""Build and exercise the layered sample through real HTTP requests."""

import os
import select
import signal
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "support"))
sys.path.insert(0, str(ROOT / "tests" / "layered-app" / "fixture"))
import postgres_server  # noqa: E402
from tax_service import TaxService  # noqa: E402
from roxum_process import children  # noqa: E402

# The quantity contract accepts 1..10: 0/1/2 and 9/10/11 cover both
# boundaries and their nearest values; "nope" covers failed integer parsing.
CASES = [
    ("/products/tea", 200, "tea: Green tea (450 cents)\n"),
    ("/products/mug", 200, "mug: Stoneware mug (1200 cents)\n"),
    ("/products/missing", 404, "product not found\n"),
    ("/products/tea/quote/0", 400, "quantity must be an integer from 1 to 10\n"),
    ("/products/tea/quote/1", 200, "Green tea: subtotal 450, tax 45, total 495 cents\n"),
    ("/products/tea/quote/2", 200, "Green tea: subtotal 900, tax 90, total 990 cents\n"),
    ("/products/tea/quote/9", 200, "Green tea: subtotal 4050, tax 405, total 4455 cents\n"),
    ("/products/tea/quote/10", 200, "Green tea: subtotal 4500, tax 450, total 4950 cents\n"),
    ("/products/tea/quote/11", 400, "quantity must be an integer from 1 to 10\n"),
    ("/products/tea/quote/nope", 400, "quantity must be an integer from 1 to 10\n"),
    ("/products/missing/quote/1", 404, "product not found\n"),
]


TAX_TOKEN = "tax-token-3f9a1c"


# The deployment's override: an ephemeral port, two threads, the test
# database, and the tax service.
def local_settings(database_port, password_file, tax_port, token_file):
    return (f"[listen]\nport = 0\nthreads = 2\n"
            f"[database]\nport = {database_port}\npassword_file = \"{password_file}\"\n"
            f"[tax]\nurl = \"http://127.0.0.1:{tax_port}/rates/JP\"\ntoken_file = \"{token_file}\"\n")


# Set by main once the database and the tax service run.
LOCAL = None
TAX = None


def start(executable, directory, local_text):
    """Starts the server with its stderr in a file: a pipe nobody reads
    could fill, and the app's `Log` would then hold the worker."""
    config = Path(directory) / "config"
    config.mkdir(exist_ok=True)
    (config / "local.toml").write_text(local_text)
    stderr = tempfile.TemporaryFile()
    server = subprocess.Popen(
        [str(executable)],
        cwd=directory,
        stdout=subprocess.PIPE,
        stderr=stderr,
        text=True,
        start_new_session=True,
    )
    server.stderr_file = stderr
    return server


def read_port(server, opt):
    ready, _, _ = select.select([server.stdout], [], [], 10)
    if not ready:
        raise AssertionError(f"{opt}: server did not report a port")
    return int(server.stdout.readline().strip())


def request(port, path):
    try:
        response = urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    return response.status, response.read().decode()


def send(port, method, path, body=None):
    """A request with an optional JSON body: its status, body, and Location."""
    data = None if body is None else body.encode()
    headers = {} if body is None else {"Content-Type": "application/json"}
    call = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, method=method, headers=headers)
    try:
        response = urllib.request.urlopen(call, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    return response.status, response.read().decode(), response.headers.get("Location")


def verify_crud(executable, directory, opt):
    """Create, read, update, and delete a product of this backend's own, and
    the answers to each kind of bad request."""
    sku = f"crud-{opt}"
    created = '{"sku": "%s", "name": "Kettle", "price_cents": 2500}' % sku
    cases = [
        ("POST", "/products", created, (201, f"{sku}: Kettle (2500 cents)\n", f"/products/{sku}")),
        ("GET", f"/products/{sku}", None, (200, f"{sku}: Kettle (2500 cents)\n", None)),
        ("POST", "/products", created, (409, "a product with this SKU already exists\n", None)),
        ("POST", "/products", "{not json", (400, None, None)),
        ("POST", "/products", '{"sku": "x", "name": "Kettle"}', (400, None, None)),
        ("POST", "/products", '{"sku": "Kettle", "name": "Kettle", "price_cents": 1}',
         (400, "sku must be 1 to 32 lowercase letters, digits, or -\n", None)),
        ("POST", "/products", '{"sku": "x", "name": "%s", "price_cents": 1}' % ("a" * 101),
         (400, "name must be 1 to 100 bytes\n", None)),
        ("POST", "/products", '{"sku": "x", "name": "Kettle", "price_cents": 10000001}',
         (400, "price_cents must be at most 10000000\n", None)),
        ("PUT", f"/products/{sku}", '{"name": "Steel kettle", "price_cents": 3200}',
         (200, f"{sku}: Steel kettle (3200 cents)\n", None)),
        ("GET", f"/products/{sku}", None, (200, f"{sku}: Steel kettle (3200 cents)\n", None)),
        ("PUT", "/products/missing", '{"name": "Kettle", "price_cents": 1}', (404, "product not found\n", None)),
        ("PUT", f"/products/{sku}", '{"name": "Kettle"}', (400, None, None)),
        ("DELETE", f"/products/{sku}", None, (204, "", None)),
        ("DELETE", f"/products/{sku}", None, (404, "product not found\n", None)),
        ("GET", f"/products/{sku}", None, (404, "product not found\n", None)),
    ]
    server = start(executable, directory, LOCAL)
    try:
        port = read_port(server, opt)
        for method, path, body, (status, expected_body, location) in cases:
            actual = send(port, method, path, body)
            expected = (status, actual[1] if expected_body is None else expected_body, location)
            assert actual == expected, (opt, method, path, body, actual)
    finally:
        stop(server)
    print(f"{opt}: {len(cases)} CRUD cases: PASS")


def stop(server):
    """Stops the server and returns its stderr."""
    if server.poll() is None:
        os.killpg(server.pid, signal.SIGTERM)
    try:
        server.wait(timeout=10)
    except subprocess.TimeoutExpired:
        # Do not let a stuck shutdown hide the original failure or leave
        # the server running.
        os.killpg(server.pid, signal.SIGKILL)
        server.wait()
    server.stderr_file.seek(0)
    logs = server.stderr_file.read().decode(errors="replace")
    server.stderr_file.close()
    return logs


def verify_tax_rate(executable, directory, opt):
    """Each quote asks the tax service, so a new rate applies at once."""
    server = start(executable, directory, LOCAL)
    try:
        port = read_port(server, opt)
        TAX.rate_percent = 20
        actual = request(port, "/products/tea/quote/1")
        expected = (200, "Green tea: subtotal 450, tax 90, total 540 cents\n")
        assert actual == expected, (opt, actual)
    finally:
        TAX.rate_percent = 10
        stop(server)


def verify_tax_unavailable(executable, directory):
    """With the tax service gone, quotes get 503 and the log says what
    failed, never the token; product pages still work."""
    process = start(executable, directory, LOCAL)
    try:
        port = read_port(process, "tax unavailable")
        TAX.stop()
        actual = request(port, "/products/tea/quote/1")
        assert actual == (503, "service unavailable\n"), actual
        actual = request(port, "/products/tea")
        assert actual == (200, "tea: Green tea (450 cents)\n"), actual
    finally:
        logs = stop(process)
    assert "tax: the tax-rate request failed" in logs, logs
    assert TAX_TOKEN not in logs
    print("tax service unavailable: 503: PASS")


def verify_unavailable(executable, directory, server):
    """With the database gone after startup, requests get 503 and the log
    says which query failed, without SQL or values."""
    process = start(executable, directory, LOCAL)
    try:
        port = read_port(process, "unavailable")
        server.stop()
        actual = request(port, "/products/tea")
        assert actual == (503, "service unavailable\n"), actual
        actual = request(port, "/products/tea/quote/1")
        assert actual == (503, "service unavailable\n"), actual
    finally:
        logs = stop(process)
    assert "products: the product view query failed" in logs, logs
    assert "products: the product query failed" in logs, logs
    assert postgres_server.APP_PASSWORD not in logs
    print("database unavailable: 503: PASS")


def verify(executable, directory, opt):
    server = start(executable, directory, LOCAL)
    try:
        port = read_port(server, opt)
        workers = children(server.pid)
        assert len(workers) == 1, (opt, workers)
        for path, expected_status, expected_body in CASES:
            actual = request(port, path)
            assert actual == (expected_status, expected_body), (opt, path, actual)
    finally:
        logs = stop(server)

    events = [line for line in logs.splitlines() if "product.quoted" in line]
    assert len(events) == 4, (opt, events)
    for quantity, total in ((1, 495), (2, 990), (9, 4455), (10, 4950)):
        assert any(
            f"quantity={quantity} total_cents={total}" in line for line in events
        ), (opt, events)
    print(f"{opt}: {len(CASES)} HTTP cases and {len(events)} events: PASS")


def main(opt, executable):
    """One backend's run (tools/check.py builds the executable), against a
    throwaway PostgreSQL and tax service of its own. The speed run also
    takes the tax service and the database away."""
    global LOCAL, TAX
    executable = Path(executable)
    with tempfile.TemporaryDirectory(prefix="roxum-layered-app-") as temporary:
        os.chmod(temporary, 0o755)
        certificates = Path(temporary) / "certificates"
        certificates.mkdir()
        postgres_server.make_certificates(certificates)
        password_file = Path(temporary) / "database-password"
        password_file.write_text(postgres_server.APP_PASSWORD + "\n")
        token_file = Path(temporary) / "tax-token"
        token_file.write_text(TAX_TOKEN + "\n")
        server = postgres_server.start(certificates)
        TAX = TaxService(TAX_TOKEN).start()
        LOCAL = local_settings(server.port, password_file, TAX.port, token_file)
        try:
            directory = Path(temporary) / f"run-{opt}"
            directory.mkdir()
            verify(executable, directory, opt)
            verify_crud(executable, directory, opt)
            verify_tax_rate(executable, directory, opt)
            if opt == "speed":
                verify_tax_unavailable(executable, directory)
                verify_unavailable(executable, directory, server)
        finally:
            server.stop()


if __name__ == "__main__":
    main(*sys.argv[1:3])
