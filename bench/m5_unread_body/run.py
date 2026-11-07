#!/usr/bin/env python3
import argparse
import json
import math
import socket
import statistics
import subprocess
import threading
import time
from datetime import datetime, timezone
from pathlib import Path


POLICIES = ("close", "buffered", "bounded")
BODY = b"x" * 1024
NEXT = b"GET / HTTP/1.1\r\nHost: x\r\n\r\n"


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[math.ceil(len(ordered) * fraction) - 1]


def process_metrics(pid):
    result = subprocess.run(
        ["ps", "-o", "time=,rss=", "-p", str(pid)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip().split()
    parts = result[0].split(":")
    cpu_seconds = int(parts[-2]) * 60 + float(parts[-1])
    if len(parts) == 3:
        cpu_seconds += int(parts[0]) * 3600
    return cpu_seconds, int(result[1])


def read_response(stream):
    status = stream.readline()
    if not status:
        raise EOFError
    headers = {}
    while True:
        line = stream.readline()
        if line == b"\r\n":
            break
        name, value = line.decode("ascii").split(":", 1)
        headers[name.lower()] = value.strip().lower()
    if headers.get("transfer-encoding") == "chunked":
        while True:
            length = int(stream.readline().strip(), 16)
            if length == 0:
                stream.readline()
                break
            stream.read(length)
            stream.read(2)
    else:
        stream.read(int(headers.get("content-length", "0")))
    return headers


def connect(port):
    sock = socket.create_connection(("127.0.0.1", port), timeout=2)
    return sock, sock.makefile("rb")


def finish_next(port, sock, stream, first_headers, counters):
    if first_headers.get("connection") == "close":
        stream.close()
        sock.close()
        counters["reconnects"] += 1
        sock, stream = connect(port)
        counters["connections"] += 1
        sock.sendall(NEXT)
    read_response(stream)
    stream.close()
    sock.close()


def buffered_operation(port, chunked, counters):
    sock, stream = connect(port)
    counters["connections"] += 1
    if chunked:
        request = (
            b"POST /unread HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
            + b"400\r\n" + BODY + b"\r\n0\r\n\r\n" + NEXT
        )
    else:
        request = (
            b"POST /unread HTTP/1.1\r\nHost: x\r\nContent-Length: 1024\r\n\r\n"
            + BODY + NEXT
        )
    started = time.perf_counter_ns()
    sock.sendall(request)
    first_headers = read_response(stream)
    next_started = time.perf_counter_ns()
    finish_next(port, sock, stream, first_headers, counters)
    ended = time.perf_counter_ns()
    counters["discarded_bytes"] += 1024 if first_headers.get("connection") != "close" else 0
    return (ended - started) / 1e6, (ended - next_started) / 1e6


def split_operation(port, chunked, delay_ms, policy, counters):
    sock, stream = connect(port)
    counters["connections"] += 1
    if chunked:
        prefix = b"POST /unread HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n400\r\nx"
        suffix = BODY[1:] + b"\r\n0\r\n\r\n" + NEXT
    else:
        prefix = b"POST /unread HTTP/1.1\r\nHost: x\r\nContent-Length: 1024\r\n\r\nx"
        suffix = BODY[1:] + NEXT
    started = time.perf_counter_ns()
    sock.sendall(prefix)
    def send_suffix():
        time.sleep(delay_ms / 1000)
        try:
            sock.sendall(suffix)
        except OSError:
            pass

    sender = threading.Thread(target=send_suffix)
    sender.start()
    first_headers = read_response(stream)
    first_ended = time.perf_counter_ns()
    sender.join()
    try:
        finish_next(port, sock, stream, first_headers, counters)
    except (EOFError, OSError):
        counters["timeouts"] += 1
        try:
            stream.close()
            sock.close()
        except OSError:
            pass
    ended = time.perf_counter_ns()
    if first_headers.get("connection") != "close":
        counters["discarded_bytes"] += 1024
    elif delay_ms > 5 and policy == "bounded":
        counters["timeouts"] += 1
    return (ended - started) / 1e6, (first_ended - started) / 1e6


def run_workload(port, name, iterations, policy):
    counters = {
        "connections": 0,
        "reconnects": 0,
        "discarded_bytes": 0,
        "timeouts": 0,
    }
    latencies = []
    occupancies = []
    started = time.perf_counter()
    for _ in range(iterations):
        if name == "buffered_content_length":
            latency, occupancy = buffered_operation(port, False, counters)
        elif name == "buffered_chunked":
            latency, occupancy = buffered_operation(port, True, counters)
        elif name == "split_content_length":
            latency, occupancy = split_operation(port, False, 1, policy, counters)
        elif name == "split_chunked":
            latency, occupancy = split_operation(port, True, 1, policy, counters)
        else:
            latency, occupancy = split_operation(port, False, 10, policy, counters)
        latencies.append(latency)
        occupancies.append(occupancy)
    elapsed = time.perf_counter() - started
    return {
        "iterations": iterations,
        "throughput_operations_per_second": iterations / elapsed,
        "next_response_latency_p50_ms": statistics.median(latencies),
        "next_response_latency_p95_ms": percentile(latencies, 0.95),
        "worker_occupancy_p95_ms": percentile(occupancies, 0.95),
        **counters,
    }


def run_policy(executable, policy, iterations):
    process = subprocess.Popen(
        [executable, policy],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    try:
        port = int(process.stdout.readline().strip())
        workloads = {}
        cpu_start, rss_peak = process_metrics(process.pid)
        for name in (
            "buffered_content_length",
            "buffered_chunked",
            "split_content_length",
            "split_chunked",
            "delayed_sender",
        ):
            count = max(20, iterations // 5) if name == "delayed_sender" else iterations
            workloads[name] = run_workload(port, name, count, policy)
            _, rss = process_metrics(process.pid)
            rss_peak = max(rss_peak, rss)
        cpu_end, _ = process_metrics(process.pid)
        return {
            "cpu_seconds": cpu_end - cpu_start,
            "peak_rss_kib": rss_peak,
            "workloads": workloads,
        }
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("executable")
    parser.add_argument("--iterations", type=int, default=200)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    results = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "iterations_per_main_workload": args.iterations,
        "body_bytes": len(BODY),
        "policies": {},
    }
    for policy in POLICIES:
        results["policies"][policy] = run_policy(
            args.executable,
            policy,
            args.iterations,
        )
    encoded = json.dumps(results, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded + "\n")
    print(encoded)


if __name__ == "__main__":
    main()
