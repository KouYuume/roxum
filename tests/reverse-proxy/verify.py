#!/usr/bin/env python3
import http.client
import os
import signal
import socket
import subprocess
import sys
import time
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, stop  # noqa: E402


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def wait_for_port(port, process, label):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"{label} exited during startup")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError(f"{label} did not listen on {port}")


def get(port, path, headers=()):
    # http.client decodes the chunked bodies the proxy may send.
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    connection.putrequest("GET", path, skip_host=True)
    connection.putheader("Host", "localhost")
    connection.putheader("Connection", "close")
    for name, value in headers:
        connection.putheader(name, value)
    connection.endheaders()
    response = connection.getresponse()
    body = response.read().decode()
    connection.close()
    return response.status, body


def start_caddy(caddy, work, app_port, attempts=3):
    """Starts Caddy in front of the app. The port is free when chosen but can
    be taken before Caddy binds it, so a failed start retries on another."""
    for attempt in range(attempts):
        proxy_port = free_port()
        config = os.path.join(work, "Caddyfile")
        with open(config, "w") as file:
            file.write(
                "{\n\tadmin off\n\tauto_https off\n}\n\n"
                # A site address without a host name serves every Host value;
                # Caddy answers an unmatched host with an empty 200.
                f"http://:{proxy_port} {{\n"
                f"\treverse_proxy 127.0.0.1:{app_port}\n"
                "}\n"
            )
        proxy = subprocess.Popen(
            [caddy, "run", "--config", config, "--adapter", "caddyfile"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            wait_for_port(proxy_port, proxy, "caddy")
            return proxy, proxy_port
        except RuntimeError:
            if proxy.poll() is None or attempt + 1 == attempts:
                stop(proxy)
                raise
    raise AssertionError("unreachable")


def main():
    app, caddy, work = sys.argv[1], sys.argv[2], sys.argv[3]
    server = subprocess.Popen([app], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, start_new_session=True)
    proxy = None
    try:
        app_port = read_port(server)
        proxy, proxy_port = start_caddy(caddy, work, app_port)

        # The app trusts loopback; Caddy connects from loopback and reports the
        # client, which is also loopback here, with the request scheme.
        status, body = get(proxy_port, "/")
        address, port, scheme, forwarded = body.split(" ")
        # ProxyHeaders removes the resolved X-Forwarded-For; Caddy's
        # X-Forwarded-Proto and X-Forwarded-Host stay.
        if status != 200 or address != "127.0.0.1" or port != "0" or scheme != "http" or forwarded != "2":
            raise RuntimeError(f"unexpected response through caddy: {status} {body!r}")

        # Caddy replaces a client-supplied X-Forwarded-For, so a spoofed value
        # never reaches the app.
        status, body = get(proxy_port, "/", [("X-Forwarded-For", "203.0.113.9"), ("X-Forwarded-Proto", "https")])
        address, _, scheme, _ = body.split(" ")
        if status != 200 or address != "127.0.0.1" or scheme != "http":
            raise RuntimeError(f"spoofed forwarding reached the app: {status} {body!r}")

        # Responses the router builds itself pass through the proxy unchanged.
        status, _ = get(proxy_port, "/missing")
        if status != 404:
            raise RuntimeError(f"unexpected status for a missing route: {status}")
    finally:
        for process in (proxy, server):
            if process is not None and process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=6)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=6)


if __name__ == "__main__":
    main()
