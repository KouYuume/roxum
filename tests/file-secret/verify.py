#!/usr/bin/env python3
"""File.read_bytes! and Secret: reading files, injected secrets, derive.

The app reads data/<name> with an 8-byte limit, loads one secret from the
environment and one from data/secret.txt in init!, and returns their
SHA-256 computed by the host. The secrets must never appear in the server's
output. Without the secret the server must not start.
"""
import hashlib
import os
import pathlib
import subprocess
import sys
import tempfile
import time
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, stop  # noqa: E402

ENV_SECRET = "env-secret-7f3a9c"
FILE_SECRET = "file-secret-c41b2e"


def get(port, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=10) as response:
        return response.read().decode().strip()


def check(label, actual, expected):
    if actual != expected:
        raise RuntimeError(f"{label}: expected {expected!r}, got {actual!r}")


def main(executable, contract_alloc):
    with tempfile.TemporaryDirectory() as directory:
        data = pathlib.Path(directory) / "data"
        data.mkdir()
        # Below, at, and above the 8-byte limit.
        (data / "seven.txt").write_text("1234567")
        (data / "eight.txt").write_text("12345678")
        (data / "nine.txt").write_text("123456789")
        (data / "binary.bin").write_bytes(b"\xff\xfe")
        (data / "dir").mkdir()
        # One trailing newline is dropped from a secret file.
        (data / "secret.txt").write_text(FILE_SECRET + "\n")

        environment = {**os.environ, "ROXUM_TEST_SECRET": ENV_SECRET}
        with tempfile.TemporaryFile() as output:
            server = subprocess.Popen([executable], cwd=directory, env=environment, stdout=subprocess.PIPE,
                                      stderr=output, text=True, start_new_session=True)
            try:
                port = read_port(server)
                check("7 bytes", get(port, "/file/seven.txt"), "ok 1234567")
                check("8 bytes", get(port, "/file/eight.txt"), "ok 12345678")
                check("9 bytes", get(port, "/file/nine.txt"), "FileTooLarge")
                check("missing", get(port, "/file/missing.txt"), "FileNotFound")
                check("directory", get(port, "/file/dir"), "FileReadFailed")
                check("not UTF-8", get(port, "/file/binary.bin"), "FileNotUtf8")
                check("env secret", get(port, "/sha256/env"), hashlib.sha256(ENV_SECRET.encode()).hexdigest())
                check("file secret", get(port, "/sha256/file"), hashlib.sha256(FILE_SECRET.encode()).hexdigest())
                check("exposed", get(port, "/exposed"), "SecretExposed")
                requests = 9
                if contract_alloc:
                    # Receiving the response can precede the worker's final
                    # allocation check. SIGTERM must not race that check.
                    # pread leaves the shared child/file offset untouched.
                    deadline = time.monotonic() + 5
                    while True:
                        log = os.pread(output.fileno(), os.fstat(output.fileno()).st_size, 0)
                        if log.count(b"roxum-contract-request-ok") >= requests:
                            break
                        if time.monotonic() >= deadline:
                            raise RuntimeError(f"request checks did not finish:\n{log.decode(errors='replace')}")
                        time.sleep(0.01)
            finally:
                stop(server)
            output.seek(0)
            log = output.read().decode(errors="replace")
            for secret in (ENV_SECRET, FILE_SECRET):
                if secret in log:
                    raise RuntimeError("a secret appeared in the server's output")
            if contract_alloc and log.count("roxum-contract-request-ok") != requests:
                raise RuntimeError(f"expected {requests} contract markers:\n{log}")

        # Without the injected secret, init! fails and the server exits.
        missing = {key: value for key, value in os.environ.items() if key != "ROXUM_TEST_SECRET"}
        result = subprocess.run([executable], cwd=directory, env=missing, capture_output=True, text=True, timeout=30)
        if result.returncode == 0 or result.stdout.strip():
            raise RuntimeError(f"the server started without its secret (status {result.returncode})")
        if "ROXUM_TEST_SECRET is not set" not in result.stderr:
            raise RuntimeError(f"unexpected startup error: {result.stderr!r}")


if __name__ == "__main__":
    main(sys.argv[1], os.environ.get("ROXUM_CONTRACT_ALLOC") == "1")
