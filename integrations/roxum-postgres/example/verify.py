#!/usr/bin/env python3
"""roxum-postgres against a real PostgreSQL, through one worker.

Typed queries, unique violations, transactions that commit and roll back,
savepoints, a transaction used after its function, requests that overlap
while the server works, statement timeouts, decode errors, TLS, SCRAM and
plain-text logins, and connections left inside a transaction.
"""
import os
import pathlib
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "tests" / "support"))
import postgres_server  # noqa: E402
from roxum_process import read_port, stop  # noqa: E402

WRONG_PASSWORD = "wrong-password-0d2a"


def request(port, method, path):
    try:
        with urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{port}{path}", method=method), timeout=30) as response:
            return response.status, response.read().decode().strip()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode().strip()


def check(label, actual, expected):
    if actual != expected:
        raise RuntimeError(f"{label}: expected {expected!r}, got {actual!r}")


def run_all(calls):
    results = [None] * len(calls)

    def call(index):
        results[index] = calls[index]()

    threads = [threading.Thread(target=call, args=(index,)) for index in range(len(calls))]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    return results


def main(executable, server_port, certificates, contract_alloc):
    with tempfile.TemporaryDirectory() as directory:
        config = pathlib.Path(directory) / "config"
        config.mkdir()
        (config / "local.toml").write_text(f"port = {server_port}\nca_file = \"{certificates / 'ca.pem'}\"\n")
        environment = {
            **os.environ,
            "ROXUM_PG_APP_PASSWORD": postgres_server.APP_PASSWORD,
            "ROXUM_PG_CLEAR_PASSWORD": postgres_server.CLEAR_PASSWORD,
            "ROXUM_PG_WRONG_PASSWORD": WRONG_PASSWORD,
        }
        requests = 0
        with tempfile.TemporaryFile() as stderr:
            server = subprocess.Popen([executable], cwd=directory, env=environment, stdout=subprocess.PIPE,
                                      stderr=stderr, text=True, start_new_session=True)
            try:
                port = read_port(server)
                get = lambda path: request(port, "GET", path)  # noqa: E731
                post = lambda path: request(port, "POST", path)  # noqa: E731

                check("create", post("/users/ada"), (201, "created 1"))
                check("duplicate", post("/users/ada"), (409, "conflict"))
                check("create bob", post("/users/bob"), (201, "created 3"))
                check("email", post("/users/ada/email/a@x"), (200, "changed 1"))
                check("list", get("/users"), (200, "1 ada a@x\n3 bob -"))
                requests += 5

                # 100 each: a refused transfer must leave both balances alone.
                check("transfer", post("/transfer/ada/bob/30"), (200, "moved"))
                check("refused", post("/transfer/ada/bob/500"), (409, "insufficient"))
                check("rest", post("/transfer/ada/bob/70"), (200, "moved"))
                check("empty", post("/transfer/ada/bob/1"), (409, "insufficient"))
                requests += 4

                check("savepoint", post("/savepoint/carol/dave"), (200, "inner rolled back"))
                check("after savepoint", get("/users"), (200, "1 ada a@x\n3 bob -\n4 carol -"))
                check("escaped", get("/escaped-transaction"), (200, "PostgresTransactionEnded"))
                requests += 3

                check("nested scope lifetimes", get("/nested-scopes"),
                      (200, ";".join(["PostgresTransactionEnded"] * 4)))
                check("aborted commit", get("/aborted-transaction"), (200, "PostgresTransactionRolledBack;0"))
                requests += 2

                # Requests waiting for the server do not hold the worker.
                probes = []
                done = threading.Event()

                def probe():
                    while not done.is_set():
                        started = time.monotonic()
                        check("fast", get("/fast"), (200, "fast"))
                        probes.append(time.monotonic() - started)
                        time.sleep(0.01)

                prober = threading.Thread(target=probe)
                prober.start()
                started = time.monotonic()
                slept = run_all([lambda: get("/sleep")] * 20)
                elapsed = time.monotonic() - started
                done.set()
                prober.join()
                requests += 20 + len(probes)
                check("sleep", slept, [(200, "slept")] * 20)
                # One at a time would take 20 * 0.3 s; new connections log in
                # first, which takes a few milliseconds each.
                if elapsed > 20 * 0.3 / 3:
                    raise RuntimeError(f"20 waiting requests took {elapsed:.2f} s")
                if statistics.median(probes) > 0.05:
                    raise RuntimeError(f"quick requests waited: median {statistics.median(probes) * 1000:.1f} ms")

                check("statement timeout", get("/statement-timeout"), (200, "PostgresQueryFailed 57014"))
                check("types", get("/types"), (200, "types ok"))
                decode = get("/decode-error")
                check("decode", decode, (200, "PostgresDecodeFailed row 1, column age: expected a number that fits the type"))
                requests += 3

                check("tls", get("/pool/secure"), (200, "tls"))
                check("untrusted", get("/pool/untrusted"), (200, "PostgresTlsFailed"))
                check("wrong password", get("/pool/wrong-password"), (200, "PostgresLoginFailed"))
                check("plain-text password", get("/pool/clear"), (200, "plain"))
                check("left in transaction", get("/left-in-transaction"), (200, "began"))
                requests += 5
                # The server notices the closed connection shortly after.
                deadline = time.monotonic() + 5
                while get("/open-transactions") != (200, "0"):
                    requests += 1
                    if time.monotonic() > deadline:
                        raise RuntimeError("a connection stayed inside a transaction")
                    time.sleep(0.05)
                requests += 1
            finally:
                stop(server)
            stderr.seek(0)
            log = stderr.read().decode(errors="replace")
        for secret in (postgres_server.APP_PASSWORD, postgres_server.CLEAR_PASSWORD, WRONG_PASSWORD, "secret-value"):
            if secret in log:
                raise RuntimeError("a secret or a value appeared in the server's output")
        other = [line for line in log.splitlines() if "roxum-contract-request-ok" not in line]
        if other:
            raise RuntimeError("unexpected stderr:\n" + "\n".join(other[:20]))
        if contract_alloc and log.count("roxum-contract-request-ok") != requests:
            raise RuntimeError(f"expected {requests} contract markers, found {log.count('roxum-contract-request-ok')}")
        print(f"20 waiting requests in {elapsed:.3f} s; quick requests median {statistics.median(probes) * 1000:.1f} ms")


if __name__ == "__main__":
    main(sys.argv[1], int(sys.argv[2]), pathlib.Path(sys.argv[3]), os.environ.get("ROXUM_CONTRACT_ALLOC") == "1")
