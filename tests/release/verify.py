#!/usr/bin/env python3
"""The app built from the release bundle starts and answers."""
import http.client
import subprocess
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, stop  # noqa: E402


def main():
    server = subprocess.Popen(
        [sys.argv[1]],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        start_new_session=True,
    )
    try:
        port = read_port(server)
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        connection.request("GET", "/")
        response = connection.getresponse()
        body = response.read()
        if response.status != 200 or body != b"from the bundle\n":
            raise RuntimeError(f"unexpected response {response.status} {body!r}")
        # The integration's bundle, which names the platform's by URL.
        if response.getheader("x-from") != "the integration's bundle":
            raise RuntimeError(f"the integration's layer did not run: {response.getheaders()!r}")
    finally:
        # SIGKILL follows if SIGTERM is ignored, so a stuck server does not
        # hide the failure above or outlive the test.
        stop(server)


if __name__ == "__main__":
    main()
