#!/usr/bin/env python3
"""M19d: the memory behind the admission and connection defaults.

Runs tests/admission/app.roc with one worker and generous limits, and
reports the worker's resident memory (RSS):

- idle, after startup
- with N requests in progress, each waiting 10 s on a delay server (as an
  outbound call does), and the median time of a quick request meanwhile
- after those requests finish
- with N idle keep-alive connections, each having served one request

Usage: measure.py <admission executable> [N ...]
       measure.py --idle <admission executable> [N ...]
"""
import asyncio
import os
import pathlib
import statistics
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "tests" / "support"))
from roxum_process import children, read_port, stop  # noqa: E402

HOLD_MILLISECONDS = 10_000


def rss_kib(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return int(out) if out else 0


async def delay_server():
    async def serve(reader, writer):
        try:
            while True:
                line = await reader.readline()
                if not line:
                    return
                await asyncio.sleep(int(line) / 1000)
                writer.write(b"done\n")
                await writer.drain()
        except (ConnectionError, ValueError):
            pass
        finally:
            writer.close()

    return await asyncio.start_server(serve, "127.0.0.1", 0, backlog=8192)


async def request(port, path):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write(f"GET {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n".encode())
    await writer.drain()
    data = await reader.read()
    writer.close()
    return data.split(b" ", 2)[1] if data else b""


async def quick_latency(port, count=20):
    times = []
    for _ in range(count):
        started = time.monotonic()
        await request(port, "/fast")
        times.append(time.monotonic() - started)
        await asyncio.sleep(0.02)
    return statistics.median(times) * 1000


async def idle_connection(port):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write(b"GET /fast HTTP/1.1\r\nHost: x\r\n\r\n")
    await writer.drain()
    await reader.readuntil(b"fast\n")
    return writer


async def measure_idle(executable, counts):
    delay = await delay_server()
    with tempfile.TemporaryDirectory() as directory:
        config = pathlib.Path(directory) / "config"
        config.mkdir()
        (config / "local.toml").write_text(
            f"delay_port = {delay.sockets[0].getsockname()[1]}\nmaximum_connections = 65536\n")
        server = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE, text=True, start_new_session=True)
        try:
            port = read_port(server)
            worker = children(server.pid)[0]
            await asyncio.sleep(0.5)
            print(f"idle worker: {rss_kib(worker)} KiB")
            for count in counts:
                writers = [await idle_connection(port) for _ in range(count)]
                await asyncio.sleep(1)
                print(f"{count} idle keep-alive connections: {rss_kib(worker)} KiB")
                for writer in writers:
                    writer.close()
                await asyncio.sleep(1)
        finally:
            stop(server, timeout=30)
    delay.close()


async def measure(executable, counts):
    delay = await delay_server()
    delay_port = delay.sockets[0].getsockname()[1]
    with tempfile.TemporaryDirectory() as directory:
        config = pathlib.Path(directory) / "config"
        config.mkdir()
        (config / "local.toml").write_text(
            f"delay_port = {delay_port}\nmaximum_queued_requests = 100000\nmaximum_requests_in_progress = 100000\n"
            "maximum_connections = 65536\nqueue_timeout_milliseconds = 60000\n")
        server = subprocess.Popen([executable], cwd=directory, stdout=subprocess.PIPE, text=True, start_new_session=True)
        try:
            port = read_port(server)
            worker = children(server.pid)[0]
            await asyncio.sleep(0.5)
            print(f"idle: {rss_kib(worker)} KiB; quick request median {await quick_latency(port):.2f} ms")
            for count in counts:
                tasks = [asyncio.create_task(request(port, f"/wait/{HOLD_MILLISECONDS}")) for _ in range(count)]
                await asyncio.sleep(min(2 + count / 1000, 6))
                held = rss_kib(worker)
                latency = await quick_latency(port)
                results = await asyncio.gather(*tasks)
                ok = sum(1 for status in results if status == b"200")
                await asyncio.sleep(0.5)
                print(f"{count} waiting: {held} KiB ({ok} answered 200); quick request median {latency:.2f} ms; "
                      f"after: {rss_kib(worker)} KiB")
        finally:
            stop(server, timeout=30)
    delay.close()


if __name__ == "__main__":
    idle = sys.argv[1] == "--idle"
    arguments = sys.argv[2:] if idle else sys.argv[1:]
    counts = [int(value) for value in arguments[1:]] or [100, 1000, 4000]
    asyncio.run((measure_idle if idle else measure)(arguments[0], counts))
