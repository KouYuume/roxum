"""Exercise the extracted trial hello on its loopback TCP listener."""
import argparse
import http.client
import os
import select
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile

from verify import ALPN_CASES, create_credentials

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "support"))
from roxum_process import read_port, stop


def check_tls(port, cert, version, worker_output):
    for offers, expected in ALPN_CASES:
        context = ssl.create_default_context(cafile=str(cert))
        context.minimum_version = context.maximum_version = version
        if offers:
            context.set_alpn_protocols(offers)
        with socket.create_connection(("127.0.0.1", port), timeout=5) as peer:
            try:
                with context.wrap_socket(peer, server_hostname="localhost") as tls:
                    if expected is None or tls.selected_alpn_protocol() != (expected if offers else None):
                        raise AssertionError(f"unexpected ALPN for {offers}")
                    check_worker_result(worker_output, expected)
            except ssl.SSLError as error:
                if expected is not None or "no application protocol" not in str(error).lower().replace("_", " "):
                    raise
                check_worker_result(worker_output, "failed")


def check_worker_result(output, expected):
    if not select.select([output], [], [], 5)[0]:
        raise TimeoutError(f"worker did not report {expected!r}")
    actual = output.readline().strip()
    if actual != expected:
        raise AssertionError(f"expected worker result {expected!r}, got {actual!r}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hello", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as directory:
        cert, key = (Path(directory) / name for name in ("cert.pem", "key.pem"))
        create_credentials(cert, key)
        for secure in (False, True):
            env = os.environ.copy()
            env.pop("ROXUM_TRIAL_CERT", None)
            env.pop("ROXUM_TRIAL_KEY", None)
            if secure:
                env.update(ROXUM_TRIAL_CERT=str(cert), ROXUM_TRIAL_KEY=str(key))
            process = subprocess.Popen([args.hello.resolve()], env=env, stdout=subprocess.PIPE,
                                       text=True, start_new_session=True)
            try:
                port = read_port(process)
                if secure:
                    for version in (ssl.TLSVersion.TLSv1_2, ssl.TLSVersion.TLSv1_3):
                        check_tls(port, cert, version, process.stdout)
                else:
                    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                    try:
                        conn.request("GET", "/")
                        response = conn.getresponse()
                        if (response.status, response.read()) != (200, b"Hello, Roc!\n"):
                            raise AssertionError("unexpected cleartext hello")
                    finally:
                        conn.close()
            finally:
                if stop(process) != 0:
                    raise RuntimeError("hello exited unsuccessfully")
    print("PASS cleartext hello and certificate-verified TLS 1.2/1.3 on the trial listener")


if __name__ == "__main__":
    main()
