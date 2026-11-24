"""Run the isolated TLS server probe with the pinned Zig and a local OpenSSL."""
import argparse
import pathlib
import select
import shlex
import shutil
import socket
import ssl
import subprocess
import tempfile

SOURCE = pathlib.Path(__file__).with_name("server.c").resolve()

ALPN_CASES = (
    (["http/1.1", "h2"], "h2"), (["h2", "http/1.1"], "h2"),
    (["other", "h2"], "h2"), (["h2"], "h2"), (["http/1.1"], "http/1.1"),
    ([], "http/1.1"), (["other"], None),
)


def create_credentials(cert, key):
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=localhost",
                    "-addext", "subjectAltName=DNS:localhost"], check=True, stdout=subprocess.DEVNULL,
                   stderr=subprocess.PIPE)


def check(server, cert, key, offers, expected):
    context = ssl.create_default_context(cafile=str(cert))
    if offers:
        context.set_alpn_protocols(offers)
    client, peer = socket.socketpair()
    with client, peer:
        client.settimeout(5)
        peer.setblocking(False)
        process = subprocess.Popen(
            [server, str(peer.fileno()), cert, key], pass_fds=(peer.fileno(),),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            peer.close()
            if not select.select([process.stdout], [], [], 5)[0]:
                raise TimeoutError("server startup timeout")
            if process.stdout.readline().strip() != "waiting for ClientHello":
                raise AssertionError("server did not signal a read wait")
            try:
                with context.wrap_socket(client, server_hostname="localhost") as channel:
                    if expected is None:
                        raise AssertionError(f"unsupported offer accepted: {offers}")
                    negotiated = channel.selected_alpn_protocol()
                    if negotiated != (expected if offers else None):
                        raise AssertionError(f"unexpected ALPN for {offers}: {negotiated!r}")
                    output, errors = process.communicate(timeout=5)
            except ssl.SSLError as error:
                if expected is not None or "no application protocol" not in str(error).lower().replace("_", " "):
                    raise
                output, errors = process.communicate(timeout=5)
            if expected is None:
                if process.returncode == 0 or output:
                    raise AssertionError((process.returncode, output, errors))
            elif process.returncode != 0 or output.strip() != expected:
                raise AssertionError((process.returncode, output, errors))
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate()


def check_write_wait(server, cert, key, *, disconnect):
    # Saturate only the server-to-client direction before passing the socket.
    client, peer = socket.socketpair()
    with client, peer:
        client.settimeout(5)
        peer.setblocking(False)
        pending = 0
        block = bytes(4096)
        while True:
            try:
                pending += peer.send(block)
            except BlockingIOError:
                break

        process = subprocess.Popen([server, str(peer.fileno()), cert, key], pass_fds=(peer.fileno(),),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            peer.close()
            incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
            context = ssl.create_default_context(cafile=str(cert))
            context.set_alpn_protocols(["h2"])
            channel = context.wrap_bio(incoming, outgoing, server_hostname="localhost")
            try:
                channel.do_handshake()
            except ssl.SSLWantReadError:
                pass
            client.sendall(outgoing.read())
            if not select.select([process.stderr], [], [], 5)[0] or process.stderr.readline() != b"waiting for writable socket\n":
                raise AssertionError("server did not report write backpressure")
            if disconnect:
                client.close()
                if process.wait(timeout=5) != 1:
                    raise AssertionError("expected handshake failure on peer close")
                return
            while pending:
                data = client.recv(min(pending, 65536))
                if not data or any(data):
                    raise AssertionError("unexpected data before the server handshake")
                pending -= len(data)
            while True:
                try:
                    channel.do_handshake()
                except ssl.SSLWantReadError:
                    client.sendall(outgoing.read())
                    data = client.recv(65536)
                    if not data:
                        raise AssertionError("server closed before completing the handshake")
                    incoming.write(data)
                else:
                    client.sendall(outgoing.read())
                    break
            output, errors = process.communicate(timeout=5)
            if (channel.selected_alpn_protocol() != "h2" or process.returncode != 0
                    or output.splitlines() not in ([b"h2"], [b"waiting for ClientHello", b"h2"])):
                raise AssertionError((process.returncode, output, errors))
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=pathlib.Path, help="exercise a previously linked probe executable")
    parser.add_argument("--check-write-wait", action="store_true", help="exercise the Mbed TLS probe under write backpressure")
    args = parser.parse_args()
    if args.check_write_wait and not args.server:
        parser.error("--check-write-wait requires a previously linked Mbed TLS --server")
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        server, cert, key = (root / name for name in ("server", "cert.pem", "key.pem"))
        if args.server:
            server = args.server.resolve()
        else:
            flags = "-lssl -lcrypto"
            if shutil.which("pkg-config"):
                flags = subprocess.check_output(["pkg-config", "--cflags", "--libs", "openssl"], text=True)
            subprocess.run(["zig", "cc", "-Wall", "-Wextra", "-Werror", str(SOURCE),
                            *shlex.split(flags), "-o", server], check=True)
        create_credentials(cert, key)
        if args.check_write_wait:
            check_write_wait(server, cert, key, disconnect=False)
            check_write_wait(server, cert, key, disconnect=True)
            print("PASS write readiness, resume and peer close")
        for offers, expected in ALPN_CASES:
            check(server, cert, key, offers, expected)
            print(f"{offers} -> {expected or 'rejected'}")


if __name__ == "__main__":
    main()
