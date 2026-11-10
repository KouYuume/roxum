#!/usr/bin/env python3
"""IPv6-only wildcard listener: peer identity, outbound TCP, admin IPC and IPv4 rejection."""
import http.client
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'support'))
from roxum_process import read_port, stop


def get(port, path='/'):
    client = http.client.HTTPConnection('::1', port, timeout=5)
    try:
        client.request('GET', path)
        response = client.getresponse()
        return response.status, response.read()
    finally:
        client.close()


def main():
    executable = str(pathlib.Path(sys.argv[1]).resolve())
    with socket.create_server(('::1', 0), family=socket.AF_INET6) as upstream:
        with socket.create_server(('::1', 0), family=socket.AF_INET6) as reserved:
            admin_port = reserved.getsockname()[1]
        errors = []

        def answer():
            try:
                upstream.settimeout(10)
                conn, _ = upstream.accept()
                with conn:
                    conn.settimeout(5)
                    data = b''
                    while len(data) < 4:
                        chunk = conn.recv(4 - len(data))
                        if not chunk:
                            raise RuntimeError('upstream closed before PING')
                        data += chunk
                    assert data == b'PING', data
                    conn.sendall(b'PONG')
            except Exception as error:
                errors.append(error)

        worker = threading.Thread(target=answer)
        worker.start()
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryFile() as log:
            config = pathlib.Path(directory) / 'config'
            config.mkdir()
            (config / 'local.toml').write_text(
                f'upstream_port = {upstream.getsockname()[1]}\nadmin_port = {admin_port}\n')
            server = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE,
                                      stderr=log, text=True, start_new_session=True)
            try:
                port = read_port(server)
                assert get(port) == (200, b'ipv6')
                assert get(port, '/outbound') == (200, b'PONG')
                assert get(admin_port, '/ready') == (200, b'ready\n')
                # A V6 listener must not silently admit IPv4 clients.
                try:
                    connection = socket.create_connection(('127.0.0.1', port), timeout=1)
                except OSError:
                    pass
                else:
                    connection.close()
                    raise AssertionError('IPv6-only listener accepted IPv4')
            finally:
                status = stop(server)
                log.seek(0)
                output = log.read().decode(errors='replace')
                assert status == 0, output
        worker.join(timeout=12)
        assert not worker.is_alive(), 'upstream did not stop'
        assert not errors, errors


if __name__ == '__main__':
    main()
