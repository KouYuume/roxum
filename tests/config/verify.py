#!/usr/bin/env python3
"""Config: the compiled-in base with config/local.toml laid over it.

The app decodes its settings in init! from config/base.toml (compiled in)
and config/local.toml in the working directory, and reports them. A missing,
malformed, mistyped, or unknown-keyed override must stop the startup with a
message that names the key path but never the value.
"""
import os
import pathlib
import subprocess
import sys
import tempfile
import urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, stop  # noqa: E402

# Appears only as a value in the override files; never in any output.
SENSITIVE = "value-9d2e4b"

BASE = """name=config-test
database=localhost:5432
replicas=replica-a,replica-b
log=Info json=false
timeout=missing"""


def get(port, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=10) as response:
        return response.read().decode().strip()


def check(label, actual, expected):
    if actual != expected:
        raise RuntimeError(f"{label}: expected {expected!r}, got {actual!r}")


def serve(executable, directory, contract_alloc, expected_config):
    with tempfile.TemporaryFile() as output:
        server = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE, stderr=output, text=True,
                                  start_new_session=True)
        try:
            port = read_port(server)
            check("merged settings", get(port, "/config"), expected_config)
            check("base settings", get(port, "/base"), BASE)
        finally:
            stop(server)
        output.seek(0)
        log = output.read().decode(errors="replace")
        if contract_alloc and log.count("roxum-contract-request-ok") != 2:
            raise RuntimeError(f"expected 2 contract markers:\n{log}")


def refuse(executable, directory, label, expected_message):
    result = subprocess.run([executable], cwd=directory, capture_output=True, text=True, timeout=30)
    if result.returncode == 0 or result.stdout.strip():
        raise RuntimeError(f"{label}: the server started (status {result.returncode})")
    if expected_message not in result.stderr:
        raise RuntimeError(f"{label}: expected {expected_message!r} in {result.stderr!r}")
    if SENSITIVE in result.stderr:
        raise RuntimeError(f"{label}: a value appeared in the startup error")


def main(executable, contract_alloc):
    with tempfile.TemporaryDirectory() as directory:
        config = pathlib.Path(directory) / "config"
        local = config / "local.toml"

        refuse(executable, directory, "no config directory", "config/local.toml not found")
        config.mkdir()
        refuse(executable, directory, "no override file", "config/local.toml not found")

        # An empty override keeps the base.
        local.write_text("")
        serve(executable, directory, contract_alloc, BASE)

        # Tables merge key by key; an array replaces the base array.
        local.write_text(
            '# production\n'
            'timeout_seconds = 30\n'
            '[database]\n'
            'host = "db.internal"\n'
            'replicas = ["replica-c"]\n'
            '[log]\n'
            'level = "debug"\n'
            'json = true\n')
        serve(executable, directory, contract_alloc, "\n".join([
            "name=config-test",
            "database=db.internal:5432",
            "replicas=replica-c",
            "log=Debug json=true",
            "timeout=30",
        ]))

        failures = [
            ("unknown key", f'[database]\nhots = "{SENSITIVE}"\n', "config: database.hots: unknown key"),
            ("wrong type", f'[database]\nport = "{SENSITIVE}"\n', "config: database.port: expected an integer, found a string"),
            ("out of range", "[database]\nport = 70000\n", "config: database.port: the integer does not fit in U16"),
            ("unknown variant", f'[log]\nlevel = "{SENSITIVE}"\n', "config: log.level: unknown variant"),
            ("tag name as written in Roc", '[log]\nlevel = "Debug"\n', "config: log.level: unknown variant"),
            ("syntax", f'[database]\nhost = "{SENSITIVE}\n', "config/local.toml: line 2: control character or newline in a string"),
            ("duplicate key", "[log]\njson = true\njson = false\n", "config/local.toml: line 3: key json is defined twice"),
        ]
        for label, text, message in failures:
            local.write_text(text)
            refuse(executable, directory, label, message)

        local.write_bytes(b"name = \"\xff\"\n")
        refuse(executable, directory, "not UTF-8", "config/local.toml is not UTF-8")

        local.unlink()
        local.mkdir()
        refuse(executable, directory, "directory", "config/local.toml cannot be read")


if __name__ == "__main__":
    main(sys.argv[1], os.environ.get("ROXUM_CONTRACT_ALLOC") == "1")
