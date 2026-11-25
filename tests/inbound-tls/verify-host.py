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
import time

from verify import ALPN_CASES, create_credentials

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "support"))
from roxum_process import read_port, stop


def create_server_chain(directory, chain, key):
    def openssl(*args):
        subprocess.run(["openssl", *args], cwd=directory, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    trust = directory / "root.pem"
    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=Trial Root", "-keyout", "root.key", "-out", trust,
            "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign")
    for name, issuer, subject, extensions in (
        ("intermediate", "root", "Trial Intermediate",
         "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign"),
        ("leaf", "intermediate", "localhost",
         "basicConstraints=critical,CA:FALSE\nsubjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth"),
    ):
        (directory / "extensions").write_text(extensions + "\n")
        openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", f"/CN={subject}",
                "-keyout", key if name == "leaf" else f"{name}.key", "-out", f"{name}.csr")
        openssl("x509", "-req", "-in", f"{name}.csr", "-days", "1", "-CA", f"{issuer}.pem",
                "-CAkey", f"{issuer}.key", "-CAcreateserial", "-extfile", "extensions", "-out", f"{name}.pem")
    chain.write_bytes((directory / "leaf.pem").read_bytes() + (directory / "intermediate.pem").read_bytes())
    return trust


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


def send_client_hello(peer, context):
    outgoing = ssl.MemoryBIO()
    client = context.wrap_bio(ssl.MemoryBIO(), outgoing, server_hostname="localhost")
    try:
        client.do_handshake()
    except ssl.SSLWantReadError:
        peer.sendall(outgoing.read())
        return
    raise AssertionError("expected the client to wait for the server flight")


def await_server_hello(peer):
    if peer.recv(1) != b"\x16":
        raise AssertionError("expected a server handshake record")


def check_handshake_admission(port, trust, output):
    address = ("127.0.0.1", port)
    context = ssl.create_default_context(cafile=str(trust))
    context.set_alpn_protocols(["h2"])
    with socket.create_connection(address, timeout=5) as first:
        send_client_hello(first, context)
        await_server_hello(first)
        with socket.create_connection(address, timeout=2) as healthy:
            with context.wrap_socket(healthy, server_hostname="localhost") as tls:
                if tls.selected_alpn_protocol() != "h2":
                    raise AssertionError("healthy peer failed to negotiate alongside stalled peer")
                check_worker_result(output, "h2")
        with socket.create_connection(address, timeout=5) as second:
            send_client_hello(second, context)
            await_server_hello(second)
            with socket.create_connection(address, timeout=5) as queued:
                send_client_hello(queued, context)
                if select.select([queued], [], [], 0.2)[0]:
                    raise AssertionError("third handshake progressed beyond the two-slot limit")
                first.close()
                check_worker_result(output, "failed")
                await_server_hello(queued)
            check_worker_result(output, "failed")
        check_worker_result(output, "failed")

    # Keep delivering part of a TLS record. Read readiness must not renew the
    # three-second admission deadline. The freed slot can serve another peer.
    with socket.create_connection(address, timeout=5) as slow:
        slow.sendall(b"\x16\x03\x03\x02\x00")
        started = time.monotonic()
        try:
            while not select.select([slow], [], [], 0.2)[0]:
                if time.monotonic() - started > 4.5:
                    raise AssertionError("partial reads extended the handshake deadline")
                slow.sendall(b"\x00")
            if slow.recv(1):
                raise AssertionError("unexpected response to incomplete TLS record")
        except (ConnectionResetError, BrokenPipeError):
            pass
        if time.monotonic() - started < 2.8:
            raise AssertionError("stalled connection closed before its handshake deadline")


def check_invalid_credentials(hello, cert, key):
    root = cert.parent
    missing = root / "missing"
    bad = root / "invalid.pem"
    bad.write_text("invalid credential contents")
    other_key = root / "other.key"
    create_credentials(root / "other.pem", other_key)
    cases = [(None, key), (cert, None), (missing, key), (cert, missing),
             (bad, key), (cert, bad), (cert, other_key)]
    unreadable = root / "unreadable.key"
    unreadable.write_bytes(key.read_bytes())
    unreadable.chmod(0)
    if not os.access(unreadable, os.R_OK):
        cases.append((cert, unreadable))
    sensitive_lines = {bad.read_bytes(), *other_key.read_bytes().splitlines(), *key.read_bytes().splitlines()}
    for certificate, private_key in cases:
        env = {k: v for k, v in os.environ.items() if k not in ("ROXUM_TRIAL_CERT", "ROXUM_TRIAL_KEY")}
        if certificate is not None:
            env["ROXUM_TRIAL_CERT"] = str(certificate)
        if private_key is not None:
            env["ROXUM_TRIAL_KEY"] = str(private_key)
        process = subprocess.Popen([hello], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=15)
            if any(line in stderr or line in stdout for line in sensitive_lines if line):
                raise AssertionError("credential contents appeared in startup diagnostics")
            if process.returncode != 1 or stdout or b"ReadinessFailed" not in stderr:
                raise AssertionError("invalid credentials did not fail before readiness")
        finally:
            if process.poll() is None:
                stop(process)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hello", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as directory:
        cert, key = (Path(directory) / name for name in ("cert.pem", "key.pem"))
        trust = create_server_chain(Path(directory), cert, key)
        check_invalid_credentials(args.hello.resolve(), cert, key)
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
                    # Existing workers retain the validated pair until shutdown.
                    cert.unlink()
                    key.unlink()
                    check_handshake_admission(port, trust, process.stdout)
                    for version in (ssl.TLSVersion.TLSv1_2, ssl.TLSVersion.TLSv1_3):
                        check_tls(port, trust, version, process.stdout)
                    with socket.create_connection(("127.0.0.1", port), timeout=5) as stalled:
                        send_client_hello(stalled, ssl.create_default_context(cafile=str(trust)))
                        await_server_hello(stalled)
                        if stop(process, timeout=2) != 0:
                            raise AssertionError("worker failed to drain an unfinished handshake")
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
    print("PASS cleartext, TLS 1.2/1.3, concurrent handshake admission, timeout and drain")


if __name__ == "__main__":
    main()
