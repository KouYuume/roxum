#!/usr/bin/env python3
"""M24 phase 2: the stages of a request, the positions of layers, and
streaming handlers, in one backend and allocator."""
import http.client
import os
import pathlib
import signal
import socket
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, ready_workers  # noqa: E402


def send(port, path, body, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    connection.request("POST", path, body=body, headers={"Connection": "close", **(headers or {})})
    response = connection.getresponse()
    data = response.read()
    stages = [value for name, value in response.getheaders() if name.lower() == "x-stage"]
    connection.close()
    return response.status, data, stages


def check(port, path, body, status, expected_body=None, stages=None, headers=None):
    actual = send(port, path, body, headers)
    if actual[0] != status:
        raise RuntimeError(f"{path} {body!r}: status {actual[0]}, expected {status}")
    if expected_body is not None and actual[1] != expected_body:
        raise RuntimeError(f"{path} {body!r}: body {actual[1]!r}, expected {expected_body!r}")
    if stages is not None and actual[2] != stages:
        raise RuntimeError(f"{path} {body!r}: stages {actual[2]!r}, expected {stages!r}")


def first_status_withheld(port, path, length, headers):
    """Sends a head that withholds its body until 100 Continue, and returns
    the first status line, so a rejection before the body shows no 100."""
    head = f"POST {path} HTTP/1.1\r\nHost: x\r\nContent-Length: {length}\r\nExpect: 100-continue\r\nConnection: close\r\n{headers}\r\n"
    with socket.create_connection(("127.0.0.1", port), timeout=10) as client:
        client.sendall(head.encode())
        with client.makefile("rb") as stream:
            first = stream.readline()
            stream.read()
    return first


def expect_continue_then_body(port, path, body):
    """Withholds the body until 100 Continue, then sends it, and returns
    everything the server sent."""
    head = f"POST {path} HTTP/1.1\r\nHost: x\r\nContent-Length: {len(body)}\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n"
    with socket.create_connection(("127.0.0.1", port), timeout=10) as client:
        client.sendall(head.encode())
        received = b""
        while b"\r\n\r\n" not in received:
            part = client.recv(4096)
            if not part:
                return received
            received += part
        client.sendall(body)
        while True:
            part = client.recv(4096)
            if not part:
                return received
            received += part


def main():
    contract_alloc = os.environ.get("ROXUM_CONTRACT_ALLOC") == "1"
    server = subprocess.Popen(
        [sys.argv[1]],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    requests = 0
    try:
        port = read_port(server)
        ready_workers(server)

        # Stage kinds run in order whatever the written order; BeforeBody
        # layers in written order; AfterHandler innermost first.
        check(port, "/order", b"x", 200, b"c:a:/order|x!", ["c", "a"])
        requests += 1

        # A reply made at layer 1 goes out through layer 0 only, not its own
        # AfterHandler and not the inner layer's.
        check(port, "/reject", b"y", 401, b"", ["a"])
        check(port, "/reject", b"y", 200, b"/reject|y", ["c", "r", "a"], {"x-key": "1"})
        requests += 2
        # Rejected before a withheld body: no 100 Continue first.
        first = first_status_withheld(port, "/reject", 3, "")
        if not first.startswith(b"HTTP/1.1 401 "):
            raise RuntimeError(f"withheld body: first status {first!r}")
        requests += 1

        # AfterBody sees the whole body before the handler; the handler can
        # extract the same body twice.
        check(port, "/signed", b"ok", 200, b"ok|ok", ["outer"])
        check(port, "/signed", b"no", 400, b"bad body", ["outer"])
        requests += 2

        # OnChunk: a limit of 5 bytes, then an uppercase transform, in written
        # order. Below, at, and above the limit.
        check(port, "/chunks", b"abcd", 200, b"/chunks|ABCD")
        check(port, "/chunks", b"abcde", 200, b"/chunks|ABCDE")
        check(port, "/chunks", b"abcdef", 413)
        requests += 3

        # A streaming handler under an 8-byte streamed limit, with an OnChunk
        # transform before its chunk! callback.
        check(port, "/stream", b"abcdefg", 200, b"ABCDEFG")
        check(port, "/stream", b"abcdefgh", 200, b"ABCDEFGH")
        check(port, "/stream", b"abcdefghi", 413)
        # A stage that rejects a part aborts the streaming handler.
        check(port, "/stream-reject", b"abc", 200, b"abc")
        check(port, "/stream-reject", b"abcd", 413)
        requests += 5

        # A client that goes away after begin! aborts the handler. The body
        # is over the 64 KiB the loop receives itself, so the handler runs.
        with socket.create_connection(("127.0.0.1", port), timeout=10) as client:
            client.sendall(b"POST /stream-any HTTP/1.1\r\nHost: x\r\nContent-Length: 65537\r\n\r\nabc")
        requests += 1

        # Extract.json answers 415 after the body; Extract.require_json before
        # a withheld body, so without it 100 Continue comes first.
        json = {"content-type": "application/json"}
        check(port, "/json-late", b'{"name":"a"}', 200, b"a", None, json)
        check(port, "/json-late", b'{"name":"a"}', 415)
        check(port, "/json-early", b'{"name":"a"}', 200, b"a", None, json)
        check(port, "/json-early", b'{"name":"a"}', 415)
        requests += 4
        first = first_status_withheld(port, "/json-early", 12, "")
        if not first.startswith(b"HTTP/1.1 415 "):
            raise RuntimeError(f"require_json: first status {first!r}")
        requests += 1
        late = expect_continue_then_body(port, "/json-late", b'{"name":"a"}')
        if not (late.startswith(b"HTTP/1.1 100 ") and b"HTTP/1.1 415 " in late):
            raise RuntimeError(f"Extract.json with a withheld body: {late!r}")
        requests += 1

        # The whole-body limit from a route's BodyLimit.whole.
        check(port, "/whole-limit", b"abc", 200, b"/whole-limit|abc")
        check(port, "/whole-limit", b"abcd", 200, b"/whole-limit|abcd")
        check(port, "/whole-limit", b"abcde", 413)
        requests += 3

        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=10) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
        stderr = server.stderr.read()
        for reason in ("TooLarge", "Rejected", "BadRequest"):
            if f"stage-test-abort {reason}" not in stderr:
                raise RuntimeError(f"abort! did not run for {reason}: {stderr!r}")
        if contract_alloc:
            markers = stderr.count("roxum-contract-request-ok")
            if markers != requests:
                raise RuntimeError(f"{markers} allocator markers for {requests} requests: {stderr!r}")
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=10)


if __name__ == "__main__":
    main()
