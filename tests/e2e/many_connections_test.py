#!/usr/bin/env python3
import os
import resource
import signal
import socket
import subprocess
import sys
import time
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, children, ready_workers  # noqa: E402

# Far more than the Roc threads. The interpreter maps and unmaps its state
# on every call, which costs a process of many threads several times what
# it costs a process of one (with the pinned compiler), so it holds fewer:
# as echo_test, coverage over load volume.
CONNECTIONS = 200 if os.environ.get("ROXUM_OPT") == "interpreter" else 1000
REQUEST = b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"


def descriptor_count(pids):
    # Linux lists every open descriptor under /proc; lsof is often absent there.
    if os.path.isdir("/proc/self/fd"):
        return sum(len(os.listdir(f"/proc/{pid}/fd")) for pid in pids)
    output = subprocess.run(
        ["lsof", "-n", "-P", "-p", ",".join(str(pid) for pid in pids)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    # One header line; every other line is one open descriptor or mapping.
    return len(output.splitlines()) - 1


def wait_for_descriptors(pids, limit, timeout=5):
    """Waits until the workers hold at most `limit` descriptors and returns
    the count, or raises after `timeout` seconds."""
    deadline = time.monotonic() + timeout
    while True:
        current = descriptor_count(pids)
        if current <= limit:
            return current
        if time.monotonic() > deadline:
            raise RuntimeError(f"descriptors did not return: limit {limit}, now {current}")
        time.sleep(0.1)


def read_response(client):
    response = bytearray()
    while b"\r\n\r\n" not in response:
        part = client.recv(4096)
        if not part:
            raise RuntimeError("connection closed before response head")
        response.extend(part)
    head, body = response.split(b"\r\n\r\n", 1)
    if not head.startswith(b"HTTP/1.1 200 "):
        raise RuntimeError(f"unexpected response head: {bytes(head)!r}")
    length = next(int(line.split(b":", 1)[1]) for line in head.split(b"\r\n") if line.lower().startswith(b"content-length:"))
    while len(body) < length:
        part = client.recv(4096)
        if not part:
            raise RuntimeError("connection closed before response body")
        body.extend(part)


def request_once(port):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
        client.sendall(REQUEST)
        read_response(client)


def main():
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    wanted = CONNECTIONS + 256
    if soft < wanted:
        resource.setrlimit(resource.RLIMIT_NOFILE, (min(wanted, hard), hard))

    server = subprocess.Popen(
        [sys.argv[1]],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        start_new_session=True,
    )
    held = []
    try:
        port = read_port(server)
        workers = ready_workers(server)
        before = descriptor_count(workers)
        request_once(port)
        # The worker closes its end of that connection only after it reads
        # the client's FIN; on a slow machine it may still be open here.
        # Counting it would make the baseline one too high.
        baseline = wait_for_descriptors(workers, before)

        # Every connection finishes one request and stays open as an idle
        # keep-alive connection, far beyond the number of Roc threads.
        for _ in range(CONNECTIONS):
            client = socket.create_connection(("127.0.0.1", port), timeout=5)
            held.append(client)
            client.sendall(REQUEST)
            read_response(client)

        # A new connection is still served while all of them are held.
        request_once(port)
        for client in held:
            client.sendall(REQUEST)
        for client in held:
            read_response(client)

        held_count = descriptor_count(workers)
        if held_count < baseline + CONNECTIONS:
            raise RuntimeError(f"held connections are not open in the workers: {baseline} -> {held_count}")

        for client in held:
            client.close()
        held.clear()

        # Closed connections return their descriptors.
        wait_for_descriptors(workers, baseline)

        if sorted(children(server.pid)) != sorted(workers):
            raise RuntimeError("a worker restarted during the test")

        os.killpg(server.pid, signal.SIGTERM)
        if server.wait(timeout=6) != 0:
            raise RuntimeError(f"server shutdown returned {server.returncode}")
    finally:
        for client in held:
            client.close()
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait(timeout=6)


if __name__ == "__main__":
    main()
