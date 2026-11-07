#!/usr/bin/env python3
"""Worker RSS while slow clients hold server-sent event streams.

    bench/stream/sse_memory.py <executable> [clients]

Opens `clients` (default 64) connections to `/many` that read only the first
bytes, waits for the streams to fill the socket buffers, and prints the sum of
the workers' RSS before, its peak while the requests run, and what is left
held after 2 seconds.
"""
import os
import pathlib
import signal
import socket
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import read_port, ready_workers  # noqa: E402


def workers_rss_kib(parent):
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss="], text=True)
    return sum(int(rss) for pid, ppid, rss in (row.split() for row in rows.splitlines()) if int(ppid) == parent)


def main():
    executable = sys.argv[1]
    clients = int(sys.argv[2]) if len(sys.argv) > 2 else 64
    server = subprocess.Popen([executable], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, start_new_session=True)
    held = []
    try:
        port = read_port(server)
        ready_workers(server)
        time.sleep(1)
        before = workers_rss_kib(server.pid)
        for _ in range(clients):
            client = socket.create_connection(("127.0.0.1", port), timeout=5)
            client.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
            client.sendall(b"GET /many HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            if not client.recv(4096).startswith(b"HTTP/1.1 200 "):
                raise RuntimeError("unexpected response")
            held.append(client)
        peak = workers_rss_kib(server.pid)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            peak = max(peak, workers_rss_kib(server.pid))
            time.sleep(0.05)
        during = workers_rss_kib(server.pid)
        print(f"workers RSS: {before / 1024:.1f} MiB idle, peak {peak / 1024:.1f} MiB, "
              f"{during / 1024:.1f} MiB after 2 s with {clients} slow streams")
    finally:
        for client in held:
            client.close()
        os.killpg(server.pid, signal.SIGKILL)
        server.wait()


if __name__ == "__main__":
    main()
