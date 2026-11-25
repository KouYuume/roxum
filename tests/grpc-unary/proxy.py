"""Isolated nginx TLS termination with verified clients and HTTP/2 upstreams."""
from contextlib import contextmanager
import pathlib
import socket
import ssl
import subprocess
import sys
import tempfile
import time

from roxum_process import stop

BINARY = pathlib.Path(__file__).resolve().parents[2] / 'zig-out/grpc-unary/proxy/nginx'


def make_credentials(directory):
    directory = pathlib.Path(directory)
    cert, key = directory / 'cert.pem', directory / 'key.pem'
    certificate_config = directory / 'certificate.cnf'
    certificate_config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=extensions\nprompt=no\n[dn]\nCN=localhost\n[extensions]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n')
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256', '-nodes',
                    '-keyout', str(key), '-out', str(cert), '-days', '1',
                    '-config', str(certificate_config)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    context = ssl.create_default_context(cafile=str(cert))
    context.set_alpn_protocols(['h2'])
    return context, cert.read_bytes()


@contextmanager
def start(upstream, directory):
    directory = pathlib.Path(directory)
    context, certificate = make_credentials(directory)
    cert, key = directory / 'cert.pem', directory / 'key.pem'
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    config = directory / 'nginx.conf'
    config.write_text('''daemon off;
master_process off;
error_log stderr notice;
pid nginx.pid;
events { worker_connections 128; }
http {
    access_log off;
    client_body_temp_path body-temp;
    proxy_temp_path proxy-temp;
    fastcgi_temp_path fastcgi-temp;
    uwsgi_temp_path uwsgi-temp;
    scgi_temp_path scgi-temp;
    server {
        listen 127.0.0.1:PORT ssl;
        http2 on;
        server_name localhost;
        ssl_certificate CERT;
        ssl_certificate_key KEY;
        location / {
            grpc_pass UPSTREAM;
            grpc_next_upstream off;
            grpc_connect_timeout 5s;
            grpc_read_timeout 5s;
            grpc_send_timeout 5s;
        }
    }
}
'''.replace('PORT', str(port)).replace('CERT', str(cert)).replace('KEY', str(key)).replace('UPSTREAM', upstream))
    with tempfile.TemporaryFile(mode='w+') as errors:
        process = subprocess.Popen([str(BINARY), '-e', 'stderr', '-p', str(directory) + '/', '-c', str(config)],
                                   stdout=errors, stderr=errors, start_new_session=True)
        try:
            deadline = time.monotonic() + 10
            while True:
                assert process.poll() is None, 'nginx exited before readiness'
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.5) as raw:
                        with context.wrap_socket(raw, server_hostname='localhost') as tls:
                            assert tls.selected_alpn_protocol() == 'h2'
                    break
                except (ConnectionRefusedError, TimeoutError):
                    assert time.monotonic() < deadline, 'nginx readiness timed out'
                    time.sleep(.02)
            yield f'localhost:{port}', ('127.0.0.1', port), context, certificate
            assert stop(process) == 0, 'nginx did not stop cleanly'
        except BaseException:
            stop(process)
            errors.seek(0)
            print(errors.read(), file=sys.stderr)
            raise
