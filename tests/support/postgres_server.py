"""A throwaway PostgreSQL server for tests.

Uses the PostgreSQL binaries when `initdb` is on the PATH or in a Debian
`/usr/lib/postgresql/<version>/bin` directory, and otherwise the
`postgres:17` Docker image. Either way the server listens on 127.0.0.1 with
TLS (the given certificate) and these roles:

- `app` (SCRAM-SHA-256, password `APP_PASSWORD`), owner of database `app`
- `clear` (plain-text password authentication, password `CLEAR_PASSWORD`)
"""
import fcntl
import glob
import os
import pathlib
import shutil
import socket
import subprocess
import tempfile
import time

APP_PASSWORD = "app-password-3b9e"
CLEAR_PASSWORD = "clear-password-71c4"

SETUP_SQL = f"""
CREATE ROLE app LOGIN PASSWORD '{APP_PASSWORD}';
CREATE ROLE clear LOGIN PASSWORD '{CLEAR_PASSWORD}';
CREATE DATABASE app OWNER app;
GRANT CONNECT ON DATABASE app TO clear;
"""

# `clear` logs in with a plain-text password; everyone else uses SCRAM.
HBA = """
local all all trust
host all clear 127.0.0.1/32 password
host all clear ::1/128 password
host all all 127.0.0.1/32 scram-sha-256
host all all ::1/128 scram-sha-256
"""


def make_certificates(directory):
    """A test CA and a server certificate for localhost in `directory`:
    ca.pem, server.pem, and server.key, readable by another user (the
    server may run as one)."""
    directory = pathlib.Path(directory)

    def openssl(*arguments):
        subprocess.run(["openssl", *arguments], check=True, capture_output=True)

    openssl("req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-days", "1",
            "-subj", "/CN=roxum test CA", "-keyout", f"{directory}/ca.key", "-out", f"{directory}/ca.pem")
    openssl("req", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-subj", "/CN=localhost",
            "-keyout", f"{directory}/server.key", "-out", f"{directory}/server.csr")
    (directory / "server.ext").write_text("subjectAltName=DNS:localhost\n")
    openssl("x509", "-req", "-in", f"{directory}/server.csr", "-CA", f"{directory}/ca.pem", "-CAkey", f"{directory}/ca.key",
            "-CAcreateserial", "-days", "1", "-extfile", f"{directory}/server.ext", "-out", f"{directory}/server.pem")
    os.chmod(directory, 0o755)
    for path in directory.iterdir():
        os.chmod(path, 0o644)


def run(command):
    """Runs `command`; on failure the error carries its output, which
    `check=True` alone would hide behind `capture_output`."""
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"{command} exited with {result.returncode}:\n{result.stderr}{result.stdout}")
    return result


def ensure_user(name):
    """Creates the user unless it exists. Tests run at the same time in one
    container: concurrent `useradd` calls overwrite each other's entries, and
    initdb then runs as a user ID that no longer exists."""
    with open("/tmp/roxum-postgres-useradd.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if subprocess.run(["id", "-u", name], capture_output=True).returncode != 0:
            run(["useradd", "-M", name])


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def find_binaries():
    initdb = shutil.which("initdb")
    if initdb:
        return pathlib.Path(initdb).parent
    for candidate in sorted(glob.glob("/usr/lib/postgresql/*/bin/initdb"), reverse=True):
        return pathlib.Path(candidate).parent
    for candidate in sorted(glob.glob("/opt/homebrew/opt/postgresql@*/bin/initdb"), reverse=True):
        return pathlib.Path(candidate).parent
    return None


def wait_until_ready(port, deadline_seconds=60):
    deadline = time.monotonic() + deadline_seconds
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return
        except OSError:
            time.sleep(0.2)
    raise RuntimeError("PostgreSQL did not start")


class LocalServer:
    def __init__(self, binaries, certificates):
        self.binaries = binaries
        self.directory = tempfile.mkdtemp(prefix="roxum-postgres-")
        self.data = pathlib.Path(self.directory) / "data"
        self.port = free_port()
        run_as = []
        # initdb refuses to run as root (the Linux test container).
        if os.geteuid() == 0:
            ensure_user("roxumpg")
            shutil.chown(self.directory, "roxumpg")
            run_as = ["runuser", "-u", "roxumpg", "--"]
        self.run_as = run_as
        run(run_as + [str(binaries / "initdb"), "-D", str(self.data), "-U", "postgres", "--auth=trust"])
        for name in ("server.pem", "server.key"):
            target = self.data / name
            shutil.copy(certificates / name, target)
            os.chmod(target, 0o600)
            if run_as:
                shutil.chown(target, "roxumpg")
        with open(self.data / "postgresql.conf", "a") as conf:
            conf.write(f"listen_addresses = '127.0.0.1'\nport = {self.port}\nunix_socket_directories = '{self.directory}'\n"
                       "ssl = on\nssl_cert_file = 'server.pem'\nssl_key_file = 'server.key'\n"
                       "password_encryption = 'scram-sha-256'\n")
        (self.data / "pg_hba.conf").write_text(HBA)
        run(run_as + [str(binaries / "pg_ctl"), "-D", str(self.data), "-l", str(pathlib.Path(self.directory) / "log"),
                      "-w", "start"])
        wait_until_ready(self.port)
        # One `-c` per statement: psql runs a single `-c` with several
        # statements in one transaction, where CREATE DATABASE is refused.
        statements = [line for line in SETUP_SQL.strip().splitlines() if line]
        arguments = [argument for statement in statements for argument in ("-c", statement)]
        run(run_as + [str(binaries / "psql"), "-h", self.directory, "-p", str(self.port), "-U", "postgres",
                      "-v", "ON_ERROR_STOP=1"] + arguments)

    def sql(self, statement, database="app"):
        run(self.run_as + [str(self.binaries / "psql"), "-h", self.directory, "-p", str(self.port), "-U", "postgres",
                           "-d", database, "-v", "ON_ERROR_STOP=1", "-c", statement])

    def stop(self):
        subprocess.run(self.run_as + [str(self.binaries / "pg_ctl"), "-D", str(self.data), "-m", "immediate", "stop"],
                       capture_output=True)
        shutil.rmtree(self.directory, ignore_errors=True)


class DockerServer:
    IMAGE = "postgres:17"

    def __init__(self, certificates):
        self.port = free_port()
        script = (
            "cp /certificates/server.pem /certificates/server.key /var/lib/postgresql/ && "
            "chown postgres /var/lib/postgresql/server.* && chmod 600 /var/lib/postgresql/server.key && "
            "exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/var/lib/postgresql/server.pem "
            "-c ssl_key_file=/var/lib/postgresql/server.key -c hba_file=/var/lib/postgresql/pg_hba.conf"
        )
        hba_dir = tempfile.mkdtemp(prefix="roxum-postgres-")
        self.hba_dir = hba_dir
        (pathlib.Path(hba_dir) / "pg_hba.conf").write_text(HBA.replace("127.0.0.1/32", "0.0.0.0/0"))
        init = pathlib.Path(hba_dir) / "setup.sql"
        init.write_text(SETUP_SQL)
        self.container = subprocess.run(
            ["docker", "run", "-d", "--rm", "-p", f"127.0.0.1:{self.port}:5432",
             "-e", "POSTGRES_HOST_AUTH_METHOD=trust",
             "-v", f"{certificates}:/certificates:ro",
             "-v", f"{init}:/docker-entrypoint-initdb.d/setup.sql:ro",
             "-v", f"{hba_dir}/pg_hba.conf:/var/lib/postgresql/pg_hba.conf:ro",
             "--entrypoint", "bash", self.IMAGE, "-c", script],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        # The image runs setup.sql, restarts, and only then listens for TCP.
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            logs = subprocess.run(["docker", "logs", self.container], capture_output=True, text=True)
            if logs.stdout.count("database system is ready to accept connections") + \
                    logs.stderr.count("database system is ready to accept connections") >= 2:
                break
            time.sleep(0.5)
        wait_until_ready(self.port)

    def sql(self, statement, database="app"):
        subprocess.run(["docker", "exec", self.container, "psql", "-U", "postgres", "-d", database, "-v", "ON_ERROR_STOP=1",
                        "-c", statement], check=True, capture_output=True)

    def stop(self):
        subprocess.run(["docker", "rm", "-f", self.container], capture_output=True)
        shutil.rmtree(self.hba_dir, ignore_errors=True)


def start(certificates):
    """Starts a server and returns it; call `stop()` when done."""
    binaries = find_binaries()
    if binaries is not None:
        return LocalServer(binaries, pathlib.Path(certificates))
    if shutil.which("docker"):
        return DockerServer(pathlib.Path(certificates))
    raise RuntimeError("no PostgreSQL: install it (initdb on the PATH) or Docker")
