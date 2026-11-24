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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=pathlib.Path, help="exercise a previously linked probe executable")
    args = parser.parse_args()
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
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                        "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost"], check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.PIPE)
        for offers, expected in [
            (["http/1.1", "h2"], "h2"), (["h2", "http/1.1"], "h2"),
            (["other", "h2"], "h2"), (["h2"], "h2"), (["http/1.1"], "http/1.1"),
            ([], "http/1.1"), (["other"], None),
        ]:
            check(server, cert, key, offers, expected)
            print(f"{offers} -> {expected or 'rejected'}")


if __name__ == "__main__":
    main()
