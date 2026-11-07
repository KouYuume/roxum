#!/usr/bin/env python3
"""HttpClient: a Roc handler calls upstream HTTP and HTTPS servers.

One worker serves every request. The upstream reads the last path segment
as an instruction (see `Upstream.respond`). The test checks framing
(Content-Length, chunked, until the end, 204, HEAD), the body limit at its
boundary, keep-alive reuse, deadlines, the per-origin limit, redirects
(count, method, cross-origin headers, https to http), the retry after a
stale idle connection, TLS (ECDSA and RSA, unknown CA, wrong name), and that
every request frees its memory.
"""
import gzip
import os
import pathlib
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, stop  # noqa: E402

SECRET = "http-client-secret-7c2e"


class Upstream:
    def __init__(self, context=None):
        upstream = self
        self.lock = threading.Lock()
        self.accepts = 0
        self.active = 0
        self.max_active = 0
        self.seen = []

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def setup(self):
                super().setup()
                self.flaky_served = {}
                with upstream.lock:
                    upstream.accepts += 1

            def log_message(self, *args):
                pass

            def do_GET(self):
                upstream.respond(self)

            do_POST = do_GET
            do_HEAD = do_GET

        class Server(ThreadingHTTPServer):
            daemon_threads = True
            # The per-origin limit check opens 64 connections at once; with
            # socketserver's backlog of 5, Linux drops some of the SYNs and
            # they arrive a second later.
            request_queue_size = 128

            def handle_error(self, request, client_address):
                # Resets from connections the test closes on purpose.
                pass

            def get_request(self):
                connection, address = super().get_request()
                if context is not None:
                    connection = context.wrap_socket(connection, server_side=True, do_handshake_on_connect=False)
                return connection, address

            def finish_request(self, request, client_address):
                if context is not None:
                    try:
                        request.do_handshake()
                    except (ssl.SSLError, OSError):
                        return
                super().finish_request(request, client_address)

        self.server = Server(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def counts(self):
        with self.lock:
            return self.accepts

    def respond(self, handler):
        segment = handler.path.rsplit("/", 1)[-1]
        length = int(handler.headers.get("Content-Length") or 0)
        body = handler.rfile.read(length) if length else b""
        with self.lock:
            self.seen.append((handler.command, segment, dict(handler.headers), body))

        def send(status, payload, headers=()):
            handler.send_response(status)
            for name, value in headers:
                handler.send_header(name, value)
            if status not in (204, 304):
                handler.send_header("Content-Length", str(len(payload)))
            handler.end_headers()
            if handler.command != "HEAD":
                handler.wfile.write(payload)

        if segment == "hello":
            send(200, b"hello")
        elif segment == "method":
            send(200, f"{handler.command} {body.decode()} {handler.headers.get('Content-Type')}".encode())
        elif segment == "chunked":
            handler.send_response(200)
            handler.send_header("Transfer-Encoding", "chunked")
            handler.end_headers()
            handler.wfile.write(b"5;ext=1\r\nhello\r\n6\r\n chunk\r\n0\r\nX-Trailer: t\r\n\r\n")
        elif segment == "until-close":
            handler.send_response(200)
            handler.send_header("Connection", "close")
            handler.end_headers()
            handler.wfile.write(b"until the end")
            handler.close_connection = True
        elif segment == "dribble":
            # Every byte of the response in its own write.
            raw = b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\ndribble"
            for index in range(len(raw)):
                handler.wfile.write(raw[index:index + 1])
                handler.wfile.flush()
                time.sleep(0.001)
        elif segment == "no-content":
            send(204, b"")
        elif segment.startswith("big-"):
            send(200, b"x" * int(segment[4:]))
        elif segment in ("slow", "hold"):
            # `hold` keeps its connection long enough for 64 of them to be
            # open at once even in the slowest backend.
            with self.lock:
                self.active += 1
                self.max_active = max(self.max_active, self.active)
            time.sleep(0.5 if segment == "slow" else 3)
            with self.lock:
                self.active -= 1
            send(200, segment.encode())
        elif segment == "hang":
            time.sleep(2)
            handler.close_connection = True
        elif segment.startswith("redirect-"):
            # `redirect-N` redirects N times in all.
            remaining = int(segment[len("redirect-"):])
            target = f"redirect-{remaining - 1}" if remaining > 1 else "hello"
            send(302, b"", [("Location", target)])
        elif segment == "see-other":
            send(303, b"", [("Location", "/x/method")])
        elif segment == "temporary":
            send(307, b"", [("Location", "/x/method")])
        elif segment.startswith("to-other-"):
            port = segment[len("to-other-"):]
            send(302, b"", [("Location", f"http://localhost:{port}/x/headers")])
        elif segment == "to-same":
            send(302, b"", [("Location", "/x/headers")])
        elif segment.startswith("to-plain-"):
            port = segment[len("to-plain-"):]
            send(302, b"", [("Location", f"http://127.0.0.1:{port}/x/hello")])
        elif segment == "headers":
            send(200, f"auth={handler.headers.get('Authorization')} kept={handler.headers.get('X-Kept')}".encode())
        elif segment.startswith("flaky"):
            # Answers once per connection and segment; a second request on
            # the same connection gets it closed with no answer, as when a
            # server closes an idle connection just as the client reuses it.
            handler.flaky_served[segment] = handler.flaky_served.get(segment, 0) + 1
            if handler.flaky_served[segment] > 1:
                handler.close_connection = True
                handler.connection.shutdown(socket.SHUT_RDWR)
                return
            send(200, b"flaky")
        elif segment == "accept":
            send(200, f"accept={handler.headers.get('Accept-Encoding')}".encode())
        elif segment == "gzip-body":
            send(200, gzip.compress(b"compressed hello"), [("Content-Encoding", "gzip")])
        elif segment == "zstd-body":
            send(200, ZSTD_HELLO, [("Content-Encoding", "zstd")])
        elif segment == "br-body":
            send(200, b"brotli-bytes", [("Content-Encoding", "br")])
        elif segment == "bad-gzip":
            send(200, b"not gzip at all", [("Content-Encoding", "gzip")])
        elif segment.startswith("gzip-big-"):
            send(200, gzip.compress(b"x" * int(segment[len("gzip-big-"):])), [("Content-Encoding", "gzip")])
        elif segment == "garbage":
            handler.wfile.write(b"NOT HTTP\r\n\r\n")
            handler.close_connection = True
        else:
            send(404, b"no such instruction")


# "zstd hello" compressed by `zstd` (Python has no Zstandard here).
ZSTD_HELLO = bytes.fromhex("28b52ffd04585100007a7374642068656c6c6f05dcba63")


def get(port, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=30) as response:
        return response.read().decode().rstrip("\n")


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


def check(label, actual, expected):
    if actual != expected:
        raise RuntimeError(f"{label}: expected {expected!r}, got {actual!r}")


def tls_context(certificates, name):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(certificates / f"{name}.pem", certificates / f"{name}.key")
    return context


def main(executable, certificates, contract_alloc):
    plain = Upstream()
    ec = Upstream(tls_context(certificates, "server-ec"))
    rsa = Upstream(tls_context(certificates, "server-rsa"))
    closed = socket.create_server(("127.0.0.1", 0))
    closed_port = closed.getsockname()[1]
    closed.close()

    with tempfile.TemporaryDirectory() as directory:
        config = pathlib.Path(directory) / "config"
        config.mkdir()
        (config / "local.toml").write_text(
            f"plain_port = {plain.port}\nec_port = {ec.port}\nrsa_port = {rsa.port}\nclosed_port = {closed_port}\n"
            f"ca_file = \"{certificates / 'ca.pem'}\"\n")
        environment = {**os.environ, "ROXUM_TEST_SECRET": SECRET}
        requests = 0
        with tempfile.TemporaryFile() as stderr:
            server = subprocess.Popen([executable], cwd=directory, env=environment, stdout=subprocess.PIPE,
                                      stderr=stderr, text=True, start_new_session=True)
            try:
                port = read_port(server)

                cases = [
                    # Framing.
                    ("/get/plain/hello", "200 hello"),
                    ("/get/plain/chunked", "200 hello chunk"),
                    ("/get/plain/until-close", "200 until the end"),
                    ("/get/plain/dribble", "200 dribble"),
                    ("/get/plain/no-content", "204 "),
                    ("/head/plain/hello", "200 "),
                    ("/get/plain/missing", "404 no such instruction"),
                    ("/get/plain/garbage", "HttpClientInvalidResponse"),
                    # The body limit of 1,000 bytes: just under, at, and over.
                    ("/small/plain/big-999", "200 " + "x" * 999),
                    ("/small/plain/big-1000", "200 " + "x" * 1000),
                    ("/small/plain/big-1001", "HttpClientBodyTooLarge"),
                    # Decompression: Accept-Encoding is sent unless the
                    # app sets it; gzip and Zstandard come back decompressed,
                    # whoever asked, within the limit; other codings and a
                    # client that does not decompress get the bytes.
                    ("/get/plain/accept", "200 accept=gzip, zstd"),
                    ("/own-accept/plain/accept", "200 accept=gzip"),
                    ("/raw/plain/accept", "200 accept=None"),
                    ("/get/plain/gzip-body", "200 compressed hello"),
                    ("/own-accept/plain/gzip-body", "200 compressed hello"),
                    ("/get/plain/zstd-body", "200 zstd hello"),
                    ("/get/plain/br-body", "200 brotli-bytes (br)"),
                    ("/get/plain/bad-gzip", "HttpClientInvalidResponse"),
                    ("/small/plain/gzip-big-1000", "200 " + "x" * 1000),
                    ("/small/plain/gzip-big-1001", "HttpClientBodyTooLarge"),
                    ("/small/plain/gzip-big-100000000", "HttpClientBodyTooLarge"),
                    # Methods and bodies.
                    ("/post/plain/method", "200 POST payload text/plain"),
                    # Redirects: 10 are followed, 11 are too many; the small
                    # client follows 2.
                    ("/get/plain/redirect-10", "200 hello"),
                    ("/get/plain/redirect-11", "HttpClientTooManyRedirects"),
                    ("/small/plain/redirect-2", "200 hello"),
                    ("/small/plain/redirect-3", "HttpClientTooManyRedirects"),
                    # 303 turns a POST into a GET without a body or its
                    # Content-Type; 307 repeats it.
                    ("/post/plain/see-other", "200 GET  None"),
                    ("/post/plain/temporary", "200 POST payload text/plain"),
                    # Credentials stay on the same origin and are dropped on
                    # another; other headers stay.
                    ("/auth/plain/to-same", "200 auth=Basic dXNlcjpwYXNz kept=kept"),
                    (f"/auth/plain/to-other-{plain.port}", "200 auth=None kept=kept"),
                    ("/secret/plain/to-same", f"200 auth=Bearer {SECRET} kept=None"),
                    (f"/secret/plain/to-other-{plain.port}", "200 auth=None kept=None"),
                    (f"/get/ec/to-plain-{plain.port}", "HttpClientInsecureRedirect"),
                    # TLS.
                    ("/get/ec/hello", "200 hello"),
                    ("/get/rsa/chunked", "200 hello chunk"),
                    ("/system/ec/hello", "TcpTlsFailed"),
                    ("/get/wrong-name/hello", "TcpTlsFailed"),
                    # Errors before and while connecting.
                    ("/get/refused/hello", "TcpConnectFailed"),
                    ("/get/unresolvable/hello", "TcpResolveFailed"),
                    ("/get/ftp/hello", "HttpClientInvalidUrl"),
                    ("/bad-header/plain/hello", "HttpClientInvalidHeader X-Bad"),
                    ("/bad-method/plain/hello", "HttpClientInvalidMethod"),
                    # The limits are set in init!; once origins are in use
                    # they cannot change.
                    ("/configure-late/plain/hello", "HttpClientInvalidConfig"),
                ]
                for path, expected in cases:
                    check(path, get(port, path), expected)
                requests += len(cases)
                # A client that does not decompress gets the gzip bytes and
                # their Content-Encoding.
                raw = get(port, "/raw/plain/gzip-body")
                if not raw.endswith(" (gzip)") or "compressed hello" in raw:
                    raise RuntimeError(f"a client that does not decompress got {raw!r}")
                requests += 1
                bad = [seen for seen in plain.seen if seen[1] == "hello" and "Injected" in seen[2]]
                check("no injected header reached the server", bad, [])

                # Keep-alive: later requests reuse the connection.
                get(port, "/get/plain/hello")
                accepts = plain.counts()
                for _ in range(10):
                    check("reuse", get(port, "/get/plain/hello"), "200 hello")
                check("connections after reuse", plain.counts(), accepts)
                accepts = ec.counts()
                for _ in range(3):
                    check("tls reuse", get(port, "/get/ec/hello"), "200 hello")
                check("tls connections after reuse", ec.counts(), accepts)
                requests += 14

                # An idle connection the server closes as it is reused: a GET
                # is sent again on a new connection, a POST is not, and a
                # client with retries off returns the error.
                check("flaky first", get(port, "/get/plain/flaky"), "200 flaky")
                check("flaky again", get(port, "/get/plain/flaky"), "200 flaky")
                check("flaky post first", get(port, "/post/plain/flaky-post"), "200 flaky")
                check("flaky post again", get(port, "/post/plain/flaky-post"), "HttpClientClosed")
                check("flaky no retry first", get(port, "/get-no-retry/plain/flaky-no-retry"), "200 flaky")
                check("flaky no retry again", get(port, "/get-no-retry/plain/flaky-no-retry"), "HttpClientClosed")
                requests += 6
                posts = [seen for seen in plain.seen if seen[0] == "POST" and seen[1] == "flaky-post"]
                check("the second POST was not sent again", len(posts), 2)

                # The deadline: a server that never answers.
                started = time.monotonic()
                check("hang", get(port, "/timeout/plain/hang"), "HttpClientTimedOut")
                overshoot = time.monotonic() - started - 0.3
                if overshoot > 0.2:
                    raise RuntimeError(f"the 300 ms deadline was overshot by {overshoot * 1000:.0f} ms")
                requests += 1

                # At most 64 connections per origin: 64 requests hold them for
                # 3 s, and requests that then wait with a 300 ms deadline get
                # `HttpClientBusy`.
                plain.max_active = 0
                holders = []
                holder_threads = []
                for _ in range(64):
                    thread = threading.Thread(target=lambda: holders.append(get(port, "/get/plain/hold")))
                    thread.start()
                    holder_threads.append(thread)
                deadline = time.monotonic() + 3
                while plain.active < 64 and time.monotonic() < deadline:
                    time.sleep(0.01)
                if plain.active < 64:
                    raise RuntimeError(f"only {plain.active} of 64 holding requests reached the upstream at once")
                waiting = run_all([lambda: get(port, "/timeout/plain/slow")] * 6)
                for thread in holder_threads:
                    thread.join()
                requests += 70
                check("holders", holders, ["200 hold"] * 64)
                check("waiting", waiting, ["HttpClientBusy"] * 6)
                if plain.max_active > 64:
                    raise RuntimeError(f"{plain.max_active} connections to one origin at once")
            finally:
                stop(server)
            stderr.seek(0)
            log = stderr.read().decode(errors="replace")
        if SECRET in log:
            raise RuntimeError("the secret appeared in the server's output")
        other = [line for line in log.splitlines() if "roxum-contract-request-ok" not in line]
        if other:
            raise RuntimeError("unexpected stderr:\n" + "\n".join(other[:20]))
        if contract_alloc and log.count("roxum-contract-request-ok") != requests:
            raise RuntimeError(f"expected {requests} contract markers, found {log.count('roxum-contract-request-ok')}")
        print(f"deadline overshoot {overshoot * 1000:.1f} ms")


if __name__ == "__main__":
    main(sys.argv[1], pathlib.Path(sys.argv[2]), os.environ.get("ROXUM_CONTRACT_ALLOC") == "1")
