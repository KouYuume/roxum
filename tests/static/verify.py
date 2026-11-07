#!/usr/bin/env python3
"""M9b-2: top-level values are computed at build time and served as is."""
import http.client
import os
import signal
import subprocess
import sys
import tempfile
import time
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, ready_workers  # noqa: E402

MARKER = "roxum-contract-request-ok"
REQUESTS = 40
PAGE = b"BAKED-32-PAGE-" + b"x" * 32
ABOUT = b"BAKED-24-PAGE-" + b"y" * 8 + b"x" * 16


def check_baked(executable):
    with open(executable, "rb") as binary:
        contents = binary.read()
    for value in (PAGE, ABOUT):
        if value not in contents:
            raise RuntimeError(f"{value!r} was not computed at build time")


def check_served(executable, contract_alloc):
    log = tempfile.TemporaryFile(mode="w+")
    server = subprocess.Popen(
        [executable],
        stdout=subprocess.PIPE,
        stderr=log,
        text=True,
        start_new_session=True,
    )
    try:
        port = read_port(server)
        ready_workers(server)
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        # Repeated requests on one connection: each gets its own copy of the
        # constant, so ownership mistakes would show up under tracking.
        for _ in range(REQUESTS // 2):
            for path, expected in (("/", PAGE), ("/about", ABOUT)):
                connection.request("GET", path)
                response = connection.getresponse()
                body = response.read()
                if response.status != 200 or body != expected:
                    raise RuntimeError(f"{path}: unexpected response {response.status} {body!r}")
        connection.close()
        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=6) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
        # The tracking allocator prints one marker per request that freed
        # everything it allocated and touched nothing it did not own.
        log.seek(0)
        markers = log.read().splitlines().count(MARKER)
        expected = REQUESTS if contract_alloc else 0
        if markers != expected:
            raise RuntimeError(f"expected {expected} allocator markers, found {markers}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=6)
        log.close()


def main():
    check_baked(sys.argv[1])
    check_served(sys.argv[1], os.environ.get("ROXUM_CONTRACT_ALLOC") == "1")


if __name__ == "__main__":
    main()
