"""Exercise the extracted trial hello on its loopback TCP listener."""
import argparse
from contextlib import ExitStack
import http.client
import json
import os
import select
import signal
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import time

from h2.connection import H2Connection
from h2.events import ConnectionTerminated, DataReceived, ResponseReceived, StreamEnded, StreamReset

from verify import ALPN_CASES, create_credentials, expect_no_application_protocol

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "support"))
from roxum_process import read_port, ready_workers, stop


def create_server_chain(directory, chain, key):
    def openssl(*args):
        subprocess.run(["openssl", *args], cwd=directory, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    trust = directory / "root.pem"
    # OpenSSL 1.1.1 appends -addext to the default CA extensions.
    root_config = directory / "root.cnf"
    root_config.write_text("[req]\ndistinguished_name=dn\n[dn]\n")
    openssl("req", "-config", root_config, "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
            "-subj", "/CN=Trial Root", "-keyout", "root.key", "-out", trust,
            "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign",
            "-addext", "subjectKeyIdentifier=hash")
    for name, issuer, subject, extensions in (
        ("intermediate", "root", "Trial Intermediate",
         "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign"),
        ("leaf", "intermediate", "localhost",
         "basicConstraints=critical,CA:FALSE\nsubjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth"),
    ):
        (directory / "extensions").write_text(extensions + "\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n")
        openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", f"/CN={subject}",
                "-keyout", key if name == "leaf" else f"{name}.key", "-out", f"{name}.csr")
        openssl("x509", "-req", "-in", f"{name}.csr", "-days", "1", "-CA", f"{issuer}.pem",
                "-CAkey", f"{issuer}.key", "-CAcreateserial", "-extfile", "extensions", "-out", f"{name}.pem")
    chain.write_bytes((directory / "leaf.pem").read_bytes() + (directory / "intermediate.pem").read_bytes())
    return trust


def expect_response(channel, body):
    with http.client.HTTPResponse(channel) as response:
        response.begin()
        if response.status != 200 or response.read() != body:
            raise AssertionError(f"unexpected HTTPS response (expected {len(body)} bytes)")


def check_https(channel):
    # One TLS record carries two requests. Read each response on the same
    # buffered file so read-ahead cannot discard the following status line.
    channel.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" * 2)
    with channel.makefile("rb") as replies:
        for _ in range(2):
            if not replies.readline().startswith(b"HTTP/1.1 200 "):
                raise AssertionError("missing pipelined HTTPS response")
            headers = http.client.parse_headers(replies)
            if int(headers["Content-Length"]) != 12 or replies.read(12) != b"Hello, Roc!\n":
                raise AssertionError("wrong pipelined HTTPS body")

    # The worker must send Continue before waiting for the body. Echo more
    # than the prebuffer limit to exercise request-fiber reads across records.
    body = bytes(range(256)) * 512
    channel.sendall(b"POST /echo HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\n"
                    + f"Content-Length: {len(body)}\r\n\r\n".encode())
    with channel.makefile("rb") as interim:
        if interim.readline() != b"HTTP/1.1 100 Continue\r\n" or interim.readline() != b"\r\n":
            raise AssertionError("missing HTTPS 100 Continue")
    channel.sendall(body)
    expect_response(channel, body)

    channel.sendall(b"GET /stream HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    expect_response(channel, b"streamed")
    # unwrap requires the peer's authenticated close notification.
    channel.unwrap().close()


def check_http2(channel, draining_process=None):
    client = H2Connection()
    client.initiate_connection()
    body = bytes(range(256)) * 96
    expected = {1: b"Hello, Roc!\n", 3: body}
    streams = {stream: bytearray() for stream in expected}
    for stream, method, path in ((1, "GET", "/"), (3, "POST", "/echo")):
        client.send_headers(stream, [(":method", method), (":scheme", "https"),
                                     (":authority", "localhost"), (":path", path)], end_stream=(stream == 1))
    client.send_data(3, body[:16384])
    client.send_data(3, body[16384:], end_stream=True)
    channel.sendall(client.data_to_send())
    successful = set()
    while streams:
        data = channel.recv(16384)
        if not data:
            raise AssertionError("HTTP/2 connection ended before both responses")
        for event in client.receive_data(data):
            if isinstance(event, (ConnectionTerminated, StreamReset)):
                raise AssertionError(f"HTTP/2 response interrupted: {event}")
            if isinstance(event, ResponseReceived):
                if dict(event.headers).get(b":status") != b"200":
                    raise AssertionError(f"unexpected HTTP status on stream {event.stream_id}")
                successful.add(event.stream_id)
            if isinstance(event, DataReceived):
                if event.stream_id not in successful:
                    raise AssertionError("DATA before response headers")
                streams[event.stream_id].extend(event.data)
                client.acknowledge_received_data(event.flow_controlled_length, event.stream_id)
            if isinstance(event, StreamEnded):
                if streams.pop(event.stream_id) != expected[event.stream_id]:
                    raise AssertionError("wrong multiplexed HTTP/2 response")
        channel.sendall(client.data_to_send())
    if draining_process is not None:
        if stop(draining_process) != 0:
            raise AssertionError("worker failed to drain HTTP/2")
        received_goaway = False
        while data := channel.recv(16384):
            for event in client.receive_data(data):
                if isinstance(event, ConnectionTerminated):
                    if event.error_code != 0 or event.last_stream_id < 3:
                        raise AssertionError(f"unexpected GOAWAY: {event}")
                    received_goaway = True
        if not received_goaway:
            raise AssertionError("missing GOAWAY during TLS shutdown")
        return
    channel.unwrap().close()


def strict_shutdown_context(cafile):
    context = ssl.create_default_context(cafile=str(cafile))
    # Some OpenSSL builds treat a bare transport EOF as a close_notify.
    context.options &= ~getattr(ssl, "OP_IGNORE_UNEXPECTED_EOF", 0)
    return context


def check_tls(port, cert, version, worker_output):
    for offers, expected in ALPN_CASES:
        context = strict_shutdown_context(cert)
        context.minimum_version = context.maximum_version = version
        if offers:
            context.set_alpn_protocols(offers)
        with socket.create_connection(("127.0.0.1", port), timeout=5) as peer:
            if expected is None:
                expect_no_application_protocol(context, peer)
                check_worker_result(worker_output, "failed")
                continue
            with context.wrap_socket(peer, server_hostname="localhost") as tls:
                if tls.selected_alpn_protocol() != (expected if offers else None):
                    raise AssertionError(f"unexpected ALPN for {offers}")
                if expected == "http/1.1":
                    check_https(tls)
                else:
                    check_http2(tls)
                check_worker_result(worker_output, expected)


def check_worker_result(output, expected):
    if output is None:
        return
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


def check_established_connections(port, trust, output):
    # The worker admits two pending handshakes. Keep three negotiated sockets
    # open and use every one, so idle eviction cannot hide a retained slot.
    context = ssl.create_default_context(cafile=str(trust))
    context.set_alpn_protocols(["http/1.1"])
    with ExitStack() as stack:
        channels = []
        for _ in range(3):
            peer = stack.enter_context(socket.create_connection(("127.0.0.1", port), timeout=5))
            channels.append(stack.enter_context(context.wrap_socket(peer, server_hostname="localhost")))
            check_worker_result(output, "http/1.1")
        for channel in channels:
            channel.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
            expect_response(channel, b"Hello, Roc!\n")


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


def configure(root, **settings):
    def literal(value):
        return json.dumps(str(value) if isinstance(value, Path) else value)
    values = dict(tls=False, chain="", key="", unix=False, socket_path=root / "listener.sock", timeout=3000, pending=2, defaults=False, short_drain=False)
    values.update((name, value) for name, value in settings.items() if value is not None)
    (root / "config/local.toml").write_text("".join(
        f"{name} = {literal(value)}\n" for name, value in values.items()))


def check_invalid_settings(hello, cert, key):
    root = cert.parent
    missing = root / "missing"
    bad = root / "invalid.pem"
    bad.write_text("invalid credential contents")
    other_key = root / "other.key"
    create_credentials(root / "other.pem", other_key)
    path_error = b"TLS credential paths"
    load_error = b"could not load TLS certificate chain"
    cases = [
        (dict(chain=None, key=key), path_error), (dict(chain=cert, key=None), path_error),
        (dict(chain=str(cert) + "\0ignored", key=key), path_error),
        (dict(chain=cert, key=str(key) + "\0ignored"), path_error),
        (dict(chain=missing, key=key), load_error), (dict(chain=cert, key=missing), load_error),
        (dict(chain=bad, key=key), load_error), (dict(chain=cert, key=bad), load_error),
        (dict(chain=cert, key=other_key), load_error),
        (dict(chain=cert, key=key, unix=True), b"requires a TCP endpoint"),
    ]
    unreadable = root / "unreadable.key"
    unreadable.write_bytes(key.read_bytes())
    unreadable.chmod(0)
    if not os.access(unreadable, os.R_OK):
        cases.append((dict(chain=cert, key=unreadable), load_error))
    sensitive_lines = {bad.read_bytes(), *other_key.read_bytes().splitlines(), *key.read_bytes().splitlines()}
    for limits in (dict(timeout=0), dict(timeout=3600001), dict(pending=0), dict(pending=65537)):
        cases.append((dict(chain=cert, key=key, **limits), b"TLS handshake timeout"))
    for settings, diagnostic in cases:
        configure(root, tls=True, **settings)
        process = subprocess.Popen([hello], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=15)
            if any(line in stderr or line in stdout for line in sensitive_lines if line):
                raise AssertionError("credential contents appeared in startup diagnostics")
            if process.returncode != 1 or stdout or b"ReadinessFailed" not in stderr or diagnostic not in stderr:
                raise AssertionError(f"expected startup rejection with {diagnostic!r}")
        finally:
            if process.poll() is None:
                stop(process)


def check_inherited_unix_listener(hello, root, cert, key):
    configure(root, unix=True)
    process = subprocess.Popen([hello], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        if not select.select([process.stdout], [], [], 15)[0]:
            raise TimeoutError("Unix listener did not start")
        if process.stdout.readline().strip() != os.fsencode(f"unix:{root}/listener.sock"):
            raise AssertionError("expected Unix listener readiness")
        worker, = ready_workers(process)
        configure(root, tls=True, chain=cert, key=key)
        os.kill(worker, signal.SIGKILL)
        diagnostic = b"the inherited listener is Unix"
        deadline = time.monotonic() + 8
        errors = b""
        while diagnostic not in errors:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([process.stderr], [], [], remaining)[0]:
                raise AssertionError("replacement worker did not reject TLS on the inherited Unix listener")
            chunk = os.read(process.stderr.fileno(), 4096)
            if not chunk:
                raise AssertionError("supervisor exited before replacement worker reported the mismatch")
            errors += chunk
    finally:
        stop(process)


def check_tls_shutdown(hello, cert, key, trust):
    configure(cert.parent, tls=True, chain=cert, key=key, short_drain=True)
    context = strict_shutdown_context(trust)
    request = b"GET / HTTP/1.1\r\nHost: localhost\r\n"
    for last_headers in (b"\r\n", b"Connection: close\r\n\r\n"):
        process = subprocess.Popen([hello], cwd=cert.parent, stdout=subprocess.PIPE, start_new_session=True)
        try:
            port = read_port(process)
            with ExitStack() as stack:
                def connect():
                    peer = stack.enter_context(socket.create_connection(("127.0.0.1", port), timeout=5))
                    return stack.enter_context(context.wrap_socket(peer, server_hostname="localhost",
                                                                  suppress_ragged_eofs=False))

                first = connect()
                first.sendall(request + b"\r\n")
                expect_response(first, b"Hello, Roc!\n")
                second = connect()  # Replaces the idle peer in the worker's only slot.
                if first.recv(1) != b"":
                    raise AssertionError("expected TLS closure on idle eviction")
                second.sendall(request + last_headers)
                expect_response(second, b"Hello, Roc!\n")
                # Leave the peer open during shutdown, both between requests
                # and after the server has initiated TLS closure.
                if stop(process) != 0 or second.recv(1) != b"":
                    raise AssertionError("worker failed to drain a completed HTTPS connection cleanly")
        finally:
            if process.poll() is None:
                stop(process)


def check_valid_settings(hello, cert, key, trust):
    for options in (dict(timeout=1, pending=1), dict(timeout=2, pending=2),
                    dict(timeout=3599999, pending=65535), dict(timeout=3600000, pending=65536),
                    dict(defaults=True)):
        configure(cert.parent, tls=True, chain=cert.name, key=key.name, **options)
        process = subprocess.Popen([hello], cwd=cert.parent, stdout=subprocess.PIPE, start_new_session=True)
        try:
            port = read_port(process)
            if options.get("defaults"):
                context = strict_shutdown_context(trust)
                context.set_alpn_protocols(["h2"])
                with socket.create_connection(("127.0.0.1", port), timeout=5) as peer:
                    with context.wrap_socket(peer, server_hostname="localhost", suppress_ragged_eofs=False) as channel:
                        if channel.selected_alpn_protocol() != "h2":
                            raise AssertionError("TLS defaults did not negotiate h2")
                        check_http2(channel, draining_process=process)
        finally:
            if stop(process) != 0:
                raise AssertionError("valid TLS listener settings failed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hello", type=Path)
    parser.add_argument("--standard", action="store_true", help="test a bundle built without worker result instrumentation")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(dir="/tmp") as directory:
        cert, key = (Path(directory) / name for name in ("cert.pem", "key.pem"))
        (cert.parent / "config").mkdir()
        trust = create_server_chain(Path(directory), cert, key)
        check_invalid_settings(args.hello.resolve(), cert, key)
        check_inherited_unix_listener(args.hello.resolve(), cert.parent, cert, key)
        check_tls_shutdown(args.hello.resolve(), cert, key, trust)
        check_valid_settings(args.hello.resolve(), cert, key, trust)
        for secure in (False, True):
            configure(cert.parent, tls=secure, chain=cert, key=key)
            process = subprocess.Popen([args.hello.resolve()], cwd=cert.parent, stdout=subprocess.PIPE,
                                       text=True, start_new_session=True)
            try:
                port = read_port(process)
                if secure:
                    # Existing workers retain the validated pair until shutdown.
                    cert.unlink()
                    key.unlink()
                    results = None if args.standard else process.stdout
                    check_handshake_admission(port, trust, results)
                    check_established_connections(port, trust, results)
                    for version in (ssl.TLSVersion.TLSv1_2, ssl.TLSVersion.TLSv1_3):
                        check_tls(port, trust, version, results)
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
    print("PASS cleartext, HTTPS keep-alive, multiplexed HTTP/2, request and response bodies, TLS admission and shutdown")


if __name__ == "__main__":
    main()
