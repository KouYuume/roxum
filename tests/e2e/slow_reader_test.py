#!/usr/bin/env python3
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import pathlib
import select

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, children, expected_thread_count, ready_workers  # noqa: E402

LARGE_BYTES = 4 * 1024 * 1024


def quick_request(port):
    started = time.monotonic()
    with socket.create_connection(("127.0.0.1", port), timeout=2) as client:
        client.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        response = bytearray()
        while True:
            part = client.recv(4096)
            if not part:
                break
            response.extend(part)
    if not response.startswith(b"HTTP/1.1 200 "):
        raise RuntimeError(f"unexpected response: {bytes(response[:64])!r}")
    return time.monotonic() - started


def read_large(client):
    client.settimeout(10)
    response = bytearray()
    while b"\r\n\r\n" not in response:
        part = client.recv(65536)
        if not part:
            raise RuntimeError("connection closed before response head")
        response.extend(part)
    head, body = response.split(b"\r\n\r\n", 1)
    if not head.startswith(b"HTTP/1.1 200 "):
        raise RuntimeError(f"unexpected response head: {bytes(head)!r}")
    length = next(int(line.split(b":", 1)[1]) for line in head.split(b"\r\n") if line.lower().startswith(b"content-length:"))
    if length != LARGE_BYTES:
        raise RuntimeError(f"unexpected content length {length}")
    while len(body) < length:
        part = client.recv(1024 * 1024)
        if not part:
            raise RuntimeError(f"connection closed after {len(body)} body bytes")
        body.extend(part)
    if body != b"x" * LARGE_BYTES:
        raise RuntimeError("large body content differs")


STREAM_BYTES = 64 * 64 * 1024


def read_stream_to_end(client):
    """Reads a chunked `/stream-large` response sent with `Connection: close`
    and returns how many body bytes (`x`) arrived."""
    client.settimeout(10)
    response = bytearray()
    while True:
        part = client.recv(1024 * 1024)
        if not part:
            break
        response.extend(part)
    head, _, body = bytes(response).partition(b"\r\n\r\n")
    if not head.startswith(b"HTTP/1.1 200 ") or not body.endswith(b"0\r\n\r\n"):
        raise RuntimeError(f"unexpected stream response: {head[:60]!r} ... {body[-20:]!r}")
    return body.count(b"x")


def check_slow_stream_readers(port, worker_count):
    # A streaming response to a reader that does not read: before streams
    # moved to the loop, each held its worker's Roc thread for the whole
    # write timeout.
    slow = []
    try:
        for _ in range(worker_count * 2):
            client = socket.create_connection(("127.0.0.1", port), timeout=2)
            client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 * 1024)
            client.sendall(b"GET /stream-large HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            slow.append(client)
        # Let every stream fill its socket buffers, so the measured requests
        # wait only behind stream steps whose chunks fit, not behind the
        # initial burst (slow under the interpreter).
        time.sleep(2)
        for _ in range(worker_count * 4):
            elapsed = quick_request(port)
            if elapsed > 1:
                raise RuntimeError(f"request waited {elapsed:.2f}s behind slow stream readers")
        # Read every stream at once: a stream left unread for the whole write
        # timeout is closed, as it should be.
        results = [None] * len(slow)

        def drain(index):
            try:
                results[index] = read_stream_to_end(slow[index])
            except Exception as error:
                results[index] = error

        threads = [threading.Thread(target=drain, args=(index,)) for index in range(len(slow))]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        for received in results:
            if isinstance(received, Exception):
                raise received
            if received != STREAM_BYTES:
                raise RuntimeError(f"stream delivered {received} of {STREAM_BYTES} bytes")
    finally:
        for client in slow:
            client.close()


def check_abandoned_streams(server, port, worker_count):
    # Clients that close mid-stream: the Roc thread releases each stream's
    # producer and heap. A leak or double free would end the worker (the
    # contract allocator build checks every stream), so the workers must
    # stay the same processes and keep answering.
    workers = sorted(children(server.pid))
    for _ in range(worker_count * 4):
        client = socket.create_connection(("127.0.0.1", port), timeout=2)
        client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 * 1024)
        client.sendall(b"GET /stream-large HTTP/1.1\r\nHost: x\r\n\r\n")
        client.recv(1024)
        client.close()
    time.sleep(1)
    for _ in range(worker_count * 2):
        quick_request(port)
    if sorted(children(server.pid)) != workers:
        raise RuntimeError("a worker restarted after clients abandoned their streams")


ECHO_BYTES = 16 * 1024
ECHO_REQUEST = (
    b"POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n" % ECHO_BYTES
    + b"y" * ECHO_BYTES
)


MEDIUM_REQUEST = b"GET /medium HTTP/1.1\r\nHost: x\r\n\r\n"


# Sending stops once this long passes without a byte going out: the clients
# do not read, so their buffers and the server's are full.
STALL_SECONDS = 0.3


def send_all_nonblocking(pending, seconds):
    """Sends each connection's bytes without waiting on any one client,
    until all are sent, nothing more goes out for `STALL_SECONDS`, or
    `seconds` pass."""
    deadline = time.monotonic() + seconds
    last_progress = time.monotonic()
    pending = [[client, data] for client, data in pending]
    while pending and time.monotonic() < deadline and time.monotonic() - last_progress < STALL_SECONDS:
        for item in pending:
            try:
                sent = item[0].send(item[1])
            except BlockingIOError:
                continue
            if sent:
                item[1] = item[1][sent:]
                last_progress = time.monotonic()
        pending = [item for item in pending if item[1]]
        time.sleep(0.01)


def check_answers_behind_full_send_buffers(port, worker_count, last_request):
    # Pipelined responses the client does not read leave the server's send
    # buffer anywhere from empty to full. A host answer sent after them (an
    # error, a bodyless stream head, the rest of 100 Continue) once waited in
    # poll on the Roc thread for the whole write timeout: on Linux, POLLOUT
    # stays off while more than about two thirds of the buffer is queued.
    # Different counts put some connection in that range, up to 4.75 MiB of
    # responses. They are 64 KiB each, built with the app: the server's
    # send buffers hold megabytes, and filling them with small answers kept
    # the interpreter busy for tens of seconds, which slowed the requests
    # measured below on a loaded machine.
    held = []
    try:
        for count in range(1, 77):
            client = socket.create_connection(("127.0.0.1", port), timeout=5)
            client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            client.setblocking(False)
            held.append((client, MEDIUM_REQUEST * count + last_request))
        send_all_nonblocking(held, 5)
        # The server goes on filling those buffers for a while: about 4 s in
        # the interpreter, longer on a small CI runner, during which other
        # requests share the CPUs with it and may wait past their own 2 s
        # timeout. An answer holding a Roc thread would hold it for the write
        # timeout (30 s), so requests must come back quickly many times in a
        # row within 20 s.
        deadline = time.monotonic() + 20
        quick_in_a_row = 0
        while quick_in_a_row < worker_count * 4:
            try:
                elapsed = quick_request(port)
            except TimeoutError:
                elapsed = float("inf")
            quick_in_a_row = quick_in_a_row + 1 if elapsed <= 1 else 0
            if quick_in_a_row == 0 and time.monotonic() > deadline:
                raise RuntimeError(f"request waited {elapsed:.2f}s behind an answer to a client that does not read")
    finally:
        for client, _ in held:
            client.close()


def exchange_until(client, data, marker, seconds):
    """Sends `data` and reads until `marker`, doing both as the socket allows,
    so a server that stops reading until its responses are read cannot stall
    the exchange."""
    deadline = time.monotonic() + seconds
    client.setblocking(False)
    response = bytearray()
    while marker not in response:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError(f"no {marker!r} after {seconds}s; {len(data)} bytes unsent")
        readable, writable, _ = select.select([client], [client] if data else [], [], remaining)
        if writable:
            try:
                data = data[client.send(data):]
            except BlockingIOError:
                pass
        if readable:
            part = client.recv(1024 * 1024)
            if not part:
                break
            response.extend(part)
    return bytes(response)


def check_continue_behind_full_send_buffer(port):
    # The last request withholds its body until 100 Continue, which comes
    # after the unread responses: the request goes to the Roc thread on its
    # head, and its first body read writes 100 Continue
    # behind them, waiting in the fiber rather than holding the thread. The
    # client sends everything before it reads, as long as the server keeps
    # reading.
    for count in (10, 100, 200):
        with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
            # Smaller buffers make Linux crawl once reading starts (see main).
            client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 * 1024)
            last = b"POST /echo HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n"
            before = exchange_until(client, ECHO_REQUEST * count + last, b"HTTP/1.1 100 Continue\r\n\r\n", 60)
            after = exchange_until(client, b"hello", b"\r\n\r\nhello", 60)
            response = before + after
            if response.count(b"HTTP/1.1 200 ") != count + 1:
                raise RuntimeError(f"pipelined requests behind 100 Continue got {response.count(b'HTTP/1.1 200 ')} of {count + 1} answers")
            if before.count(b"HTTP/1.1 200 ") != count:
                raise RuntimeError("100 Continue came before the earlier responses")

def main():
    server = subprocess.Popen(
        [sys.argv[1]],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        start_new_session=True,
    )
    slow = []
    try:
        port = read_port(server)
        ready_workers(server)
        # Load sized to hold every thread of the process at once.
        worker_count = expected_thread_count()

        # Slow readers: each response is far larger than the socket buffers,
        # and nothing is read yet. With blocking writes these would hold every
        # Roc thread until the write timeout.
        for _ in range(worker_count * 2):
            client = socket.create_connection(("127.0.0.1", port), timeout=2)
            # 64 KiB keeps the 4 MiB response pending. Smaller buffers make
            # Linux crawl once reading starts (16 KiB took 27 s per response),
            # past the response write timeout.
            client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 * 1024)
            client.sendall(b"GET /large HTTP/1.1\r\nHost: x\r\n\r\n")
            slow.append(client)
        time.sleep(0.5)

        for _ in range(worker_count * 4):
            elapsed = quick_request(port)
            if elapsed > 1:
                raise RuntimeError(f"request waited {elapsed:.2f}s behind slow readers")

        # The loop finishes every pending response, and the connections stay
        # usable for another request.
        for client in slow:
            read_large(client)
        for client in slow:
            client.sendall(b"GET /large HTTP/1.1\r\nHost: x\r\n\r\n")
        for client in slow:
            read_large(client)

        check_slow_stream_readers(port, worker_count)
        check_answers_behind_full_send_buffers(port, worker_count, b"GET /a/../b HTTP/1.1\r\nHost: x\r\n\r\n")
        check_answers_behind_full_send_buffers(port, worker_count, b"HEAD /stream HTTP/1.1\r\nHost: x\r\n\r\n")
        check_answers_behind_full_send_buffers(
            port,
            worker_count,
            b"POST /echo HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhello",
        )
        check_continue_behind_full_send_buffer(port)
        check_abandoned_streams(server, port, worker_count)

        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=6) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
    finally:
        for client in slow:
            client.close()
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=6)


if __name__ == "__main__":
    main()
