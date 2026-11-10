#!/usr/bin/env python3
"""Filesystem listeners: HTTP, peer identity, IPC, ownership and startup refusal."""
from contextlib import closing
import http.client
import json
import os
import pathlib
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'support'))
from roxum_process import stop


class Client(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.host)


def get(path, route='/'):
    with closing(Client(str(path), timeout=5)) as client:
        client.request('GET', route, headers={'Host': 'localhost'})
        response = client.getresponse()
        return response.status, response.read()


def launch(executable, directory, path, metrics):
    config = pathlib.Path(directory) / 'config'
    config.mkdir(exist_ok=True)
    (config / 'local.toml').write_text(
        f'path = {json.dumps(str(path))}\nmetrics_path = {json.dumps(str(metrics))}\n')
    return subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, start_new_session=True)


def ready(server, path):
    assert select.select([server.stdout], [], [], 15)[0], 'startup timed out'
    line = server.stdout.readline().strip()
    assert line == f'unix:{path}', (line, server.poll())


def child_pids(parent):
    rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid='], text=True).splitlines()
    return [row.split()[0] for row in rows if len(row.split()) == 2 and row.split()[1] == str(parent)]


def main():
    executable = str(pathlib.Path(sys.argv[1]).resolve())
    # Short paths leave room for the portable sockaddr_un limit on macOS.
    with tempfile.TemporaryDirectory(prefix='roxum-unix-', dir='/tmp') as directory:
        path = pathlib.Path(directory) / 'http.sock'
        metrics = pathlib.Path(directory) / 'metrics.sock'
        server = launch(executable, directory, path, metrics)
        try:
            ready(server, path)
            assert get(path) == (200, b'unix')
            assert get(metrics, '/ready') == (200, b'ready\n')
            with closing(Client(str(path), timeout=5)) as client:
                for body in [b'', b'body over a Unix stream']:
                    client.request('POST', '/echo', body, headers={'Host': 'localhost'})
                    response = client.getresponse()
                    assert (response.status, response.read()) == (200, body)
            # Restart every worker so a surviving worker cannot mask a failed handoff.
            children = child_pids(server.pid)
            assert len(children) == 2, children
            for child in children:
                os.kill(int(child), signal.SIGKILL)
            deadline = time.monotonic() + 8
            while True:
                children_after = child_pids(server.pid)
                if len(children_after) == 2 and not set(children).intersection(children_after) and get(metrics, '/ready') == (200, b'ready\n'):
                    break
                assert time.monotonic() < deadline, 'worker did not restart'
                time.sleep(0.05)
            assert get(path) == (200, b'unix')
        finally:
            assert stop(server) == 0, server.stderr.read()
        assert not path.exists() and not metrics.exists(), 'owned socket was not removed'

        # Normal restart can bind the path after shutdown.
        server = launch(executable, directory, path, metrics)
        try:
            ready(server, path)
            # A replacement regular file must survive cleanup.
            path.unlink()
            path.write_text('replacement')
        finally:
            assert stop(server) == 0, server.stderr.read()
        assert path.read_text() == 'replacement'

        # Replacing the name with a different socket must preserve that inode too.
        path.unlink()
        server = launch(executable, directory, path, metrics)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as replacement:
            try:
                ready(server, path)
                path.unlink()
                replacement.bind(str(path))
                inode = path.stat().st_ino
            finally:
                assert stop(server) == 0, server.stderr.read()
            assert path.stat().st_ino == inode
        path.unlink()
        path.write_text('replacement')

        # Existing regular files and symlinks must never be replaced on startup.
        def refused(chosen, admin=metrics):
            process = launch(executable, directory, chosen, admin)
            try:
                stdout, stderr = process.communicate(timeout=15)
                assert process.returncode != 0 and not stdout, (stdout, stderr)
            finally:
                if process.poll() is None:
                    stop(process)

        refused(path)
        assert path.read_text() == 'replacement'
        link = pathlib.Path(directory) / 'link.sock'
        link.symlink_to(path)
        refused(link)
        assert link.is_symlink() and path.read_text() == 'replacement'
        path.unlink()
        # Binding an occupied socket must not steal its name.
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as occupied:
            occupied.bind(str(path))
            occupied.listen()
            inode = path.stat().st_ino
            refused(path)
            assert path.stat().st_ino == inode
        refused(path)  # A stale socket is also left to the operator.
        path.unlink()
        # A metrics failure must clean the application's already-created socket.
        metrics.write_text('occupied')
        refused(path)
        assert not path.exists() and metrics.read_text() == 'occupied'
        metrics.unlink()
        # Nearest valid byte lengths below and at the shared OS limit.
        for length in [102, 103]:
            long_path = pathlib.Path(directory) / ('s' * (length - len(directory) - 1))
            server = launch(executable, directory, long_path, metrics)
            try:
                ready(server, long_path)
                assert get(long_path) == (200, b'unix')
            finally:
                assert stop(server) == 0, server.stderr.read()
            assert not long_path.exists()
        for invalid in ['relative.sock', '', '/tmp/' + 'x' * 99, '/tmp/x\x00y', '/tmp/x\ny', '/tmp/x\ry', str(path / 'missing.sock')]:
            refused(invalid)
        assert not path.exists() and not metrics.exists()


if __name__ == '__main__':
    main()
