"""Start a streaming fixture and connect clients through its selected transport."""
from contextlib import contextmanager, ExitStack
from dataclasses import dataclass
import json
from pathlib import Path
import select
import socket
import ssl
import subprocess

import grpc

from roxum_process import read_port, stop
import proxy


def scheme(sock):
    return "https" if isinstance(sock, ssl.SSLSocket) else "http"


@dataclass
class Client:
    address: tuple | str
    target: str
    context: ssl.SSLContext | None
    certificate: bytes | None

    def channel(self):
        options = (('grpc.enable_retries', 0), ('grpc.enable_http_proxy', 0))
        if self.context:
            return grpc.secure_channel(self.target, grpc.ssl_channel_credentials(self.certificate), options=options)
        return grpc.insecure_channel(self.target, options=options)

    def connect(self):
        sock = socket.socket(socket.AF_UNIX if isinstance(self.address, str) else socket.AF_INET)
        try:
            sock.settimeout(10)
            if sock.family == socket.AF_INET:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            sock.connect(self.address)
            if self.context:
                sock = self.context.wrap_socket(sock, server_hostname='localhost', suppress_ragged_eofs=False)
                assert sock.selected_alpn_protocol() == 'h2'
            return sock
        except BaseException:
            sock.close()
            raise


@contextmanager
def listener(executable, directory, errors, unix, mode, backend):
    directory = Path(directory)
    path = str(directory / 'rpc.sock') if unix else ''
    config = directory / 'config'
    config.mkdir()
    threads = 1 if backend == 'interpreter' else 2
    direct_tls = mode == 'tls'
    (config / 'local.toml').write_text(f'path = {json.dumps(path)}\nthreads = {threads}\ntls = {json.dumps(direct_tls)}\n')
    context, certificate = proxy.make_credentials(directory) if direct_tls else (None, None)
    if direct_tls:
        context.options &= ~getattr(ssl, 'OP_IGNORE_UNEXPECTED_EOF', 0)
    with ExitStack() as stack:
        process = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE, stderr=errors,
                                   text=True, start_new_session=True)
        stack.callback(process.stdout.close)
        stack.callback(stop, process)
        if unix:
            assert select.select([process.stdout], [], [], 30)[0], 'startup timeout'
            target = process.stdout.readline().strip()
            assert target == 'unix:' + path, target
            address = path
        else:
            port = read_port(process)
            address = ('127.0.0.1', port)
            target = f'127.0.0.1:{port}'
        if mode == 'proxy':
            upstream = 'unix:' + path if unix else 'grpc://' + target
            target, address, context, certificate = stack.enter_context(proxy.start(upstream, directory))
        yield process, Client(address, target, context, certificate)
