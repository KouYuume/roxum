"""Local wire fixtures for failed logins and whole-exchange deadlines.

Real PostgreSQL normally closes failed logins and enforces statement_timeout,
which can hide client cleanup and slow-delivery bugs. These peers keep the
socket open or split messages. Exact deadline boundaries are pure Roc tests;
the wire tests cover completion inside the budget and activity beyond it.
"""
import base64
import hashlib
import hmac
import os
import pathlib
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "tests" / "support"))
from roxum_process import read_port, stop  # noqa: E402


def message(kind, body=b""):
    return kind + struct.pack("!I", len(body) + 4) + body


def exact(connection, count):
    result = bytearray()
    while len(result) < count:
        part = connection.recv(count - len(result))
        if not part:
            raise EOFError("unexpected end of protocol message")
        result.extend(part)
    return bytes(result)


def startup(listener):
    connection, _ = listener.accept()
    connection.settimeout(5)
    length = struct.unpack("!I", exact(connection, 4))[0]
    exact(connection, length - 4)
    return connection


def query(connection):
    while True:
        kind = exact(connection, 1)
        length = struct.unpack("!I", exact(connection, 4))[0]
        exact(connection, length - 4)
        if kind == b"S":
            return


def run_case(executable, label, peer, expected, password=False):
    with socket.create_server(("127.0.0.1", 0)) as listener, tempfile.TemporaryDirectory() as directory, tempfile.TemporaryFile() as stderr:
        listener.settimeout(5)
        errors = []

        def serve():
            try:
                peer(listener)
            except Exception as error:
                errors.append(error)

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        config = pathlib.Path(directory) / "config"
        config.mkdir()
        (config / "local.toml").write_text(f"port = {listener.getsockname()[1]}\npassword = {str(password).lower()}\n")
        app = subprocess.Popen([str(executable)], cwd=directory, stdout=subprocess.PIPE,
                               stderr=stderr, text=True, start_new_session=True,
                               env={**os.environ, "ROXUM_TEST_PASSWORD": "fixture-password"})
        try:
            port = read_port(app)
            for wanted in expected:
                with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=6) as response:
                    actual = response.read().decode()
                if actual != wanted:
                    raise AssertionError(f"{label}: expected {wanted!r}, got {actual!r}")
            thread.join(6)
            if thread.is_alive():
                raise AssertionError(f"{label}: peer did not finish")
            if errors:
                raise AssertionError(f"{label}: {errors[0]}") from errors[0]
        finally:
            stop(app)


def failed_login(payload):
    def peer(listener):
        # Each failure must close its socket. The next request must open
        # another connection and send startup again, never a query here.
        for _ in range(2):
            with startup(listener) as connection:
                connection.sendall(message(b"R", payload))
                if connection.recv(1) != b"":
                    raise AssertionError("a failed login connection was reused")
    return peer


def timed_reply(mode):
    def peer(listener):
        with startup(listener) as connection:
            connection.sendall(message(b"R", struct.pack("!I", 0)) + message(b"Z", b"I"))
            query(connection)
            parts = [message(b"1"), message(b"2"), message(b"C", b"SELECT 1\0"), message(b"Z", b"I")]
            if mode == "fragment":
                parts = [b"C", b"\0", b"\0", b"\0"]
            if mode == "notice":
                parts = [message(b"N", b"Mwaiting\0\0")] * 4
            try:
                for part in parts:
                    time.sleep(0.1 if mode == "within" else 0.4)
                    connection.sendall(part)
            except (BrokenPipeError, ConnectionResetError):
                if mode == "within":
                    raise
    return peer


def auth(code, data=b""):
    return message(b"R", struct.pack("!I", code) + data)


def client_password(connection):
    assert exact(connection, 1) == b"p"
    length = struct.unpack("!I", exact(connection, 4))[0]
    return exact(connection, length - 4)


def scram_reply(mode):
    def peer(listener):
        with startup(listener) as connection:
            if mode == "early-ready":
                connection.sendall(message(b"Z", b"I"))
            else:
                initial_auth = auth(10, b"SCRAM-SHA-256\0\0")
                connection.sendall(initial_auth)
                initial = client_password(connection)
                bare = initial.split(b"n,,", 1)[1]
                nonce = bare.split(b"r=", 1)[1]
                first = b"r=" + nonce + b"server,s=QUJD,i=4096"
                if mode == "duplicate-start":
                    connection.sendall(initial_auth)
                elif mode == "early-ok":
                    connection.sendall(auth(0) + message(b"Z", b"I"))
                else:
                    connection.sendall(auth(11, first))
                    final = client_password(connection)
                    without_proof, proof = final.rsplit(b",p=", 1)
                    transcript = b",".join([bare, first, without_proof])
                    salted = hashlib.pbkdf2_hmac("sha256", b"fixture-password", b"ABC", 4096)
                    client_key = hmac.digest(salted, b"Client Key", "sha256")
                    client_signature = hmac.digest(hashlib.sha256(client_key).digest(), transcript, "sha256")
                    assert base64.b64decode(proof) == bytes(a ^ b for a, b in zip(client_key, client_signature))
                    signature = base64.b64encode(hmac.digest(hmac.digest(salted, b"Server Key", "sha256"), transcript, "sha256"))
                    server_final = auth(12, b"v=" + signature)
                    if mode == "missing-final":
                        connection.sendall(auth(0) + message(b"Z", b"I"))
                    elif mode == "duplicate-continue":
                        connection.sendall(auth(11, first))
                    elif mode == "bad-signature":
                        connection.sendall(auth(12, b"v=wrong"))
                    elif mode == "missing-ok":
                        connection.sendall(server_final + message(b"Z", b"I"))
                    elif mode == "duplicate-final":
                        connection.sendall(server_final + server_final)
                    else:
                        connection.sendall(server_final + auth(0) + message(b"Z", b"I"))
            if mode == "valid":
                query(connection)
                connection.sendall(message(b"C", b"SELECT 1\0") + message(b"Z", b"I"))
            else:
                try:
                    extra = connection.recv(1)
                except ConnectionResetError:
                    extra = b""  # Closing with unread server messages may reset.
                if extra != b"":
                    raise AssertionError("invalid authentication advanced or sent a query")
    return peer


def main(executable):
    # Distinct login failure paths that do not rely on peer closure:
    # unsupported method, absent password, absent supported SASL mechanism,
    # and a mismatching server signature.
    for label, payload in [
        ("unsupported", struct.pack("!I", 5) + b"abcd"),
        ("missing password", struct.pack("!I", 3)),
        ("unsupported SASL", struct.pack("!I", 10) + b"OTHER\0\0"),
        ("signature mismatch", struct.pack("!I", 12) + b"v=wrong"),
    ]:
        run_case(executable, label, failed_login(payload), ["login-failed"] * 2)
    # Authentication state classes: successful SCRAM, missing mandatory steps,
    # invalid proof, and repeated / out-of-order steps. Trust is covered below.
    for mode in ("valid", "early-ready", "early-ok", "missing-final", "missing-ok",
                 "bad-signature", "duplicate-start", "duplicate-continue", "duplicate-final"):
        run_case(executable, mode, scram_reply(mode),
                 ["ok" if mode == "valid" else "login-failed"], password=True)
    # Every individual read is ready within 1,100 ms; only the total budget
    # distinguishes the slow complete messages, fragments, and notices.
    for mode in ("within", "messages", "fragment", "notice"):
        run_case(executable, mode, timed_reply(mode), ["ok" if mode == "within" else "timed-out"])


if __name__ == "__main__":
    main(sys.argv[1])
