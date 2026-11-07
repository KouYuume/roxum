#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path


def process_tree_metrics(root_pid, elapsed_seconds):
    rows = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,%cpu=,rss="],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()
    parsed = [line.split() for line in rows]
    descendants = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, ppid, _, _ in parsed:
            if int(ppid) in descendants and int(pid) not in descendants:
                descendants.add(int(pid))
                changed = True
    cpu = sum(float(row[2]) for row in parsed if int(row[0]) in descendants)
    rss = sum(int(row[3]) for row in parsed if int(row[0]) in descendants)
    fd_count = None
    if shutil.which("lsof"):
        fd_rows = subprocess.run(
            [
                "lsof",
                "-n",
                "-P",
                "-a",
                "-p",
                ",".join(map(str, descendants)),
                "-d",
                "0-999999",
            ],
            check=False,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
        fd_count = max(0, len(fd_rows) - 1)
    return {
        "elapsed_seconds": elapsed_seconds,
        "cpu_percent_sample": cpu,
        "rss_kib": rss,
        "fd_count": fd_count,
        "process_count": len(descendants),
    }


def append_progress(path, event):
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as stream:
        stream.write(json.dumps(event) + "\n")
        stream.flush()
        os.fsync(stream.fileno())


def run_once(executable, oha, architecture, duration, concurrency, sample_interval, qps, progress_output):
    server = subprocess.Popen(
        [executable, architecture],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        start_new_session=True,
    )
    try:
        port = int(server.stdout.readline().strip())
        command = [
            oha,
            "--no-tui",
            "--output-format",
            "json",
            "--wait-ongoing-requests-after-deadline",
            "-z",
            duration,
            "-c",
            str(concurrency),
            f"http://127.0.0.1:{port}/",
        ]
        if qps is not None:
            command[1:1] = ["-q", str(qps)]
        time.sleep(0.25)
        warm_baseline = process_tree_metrics(server.pid, 0.0)
        append_progress(progress_output, {"event": "warm_baseline", "metrics": warm_baseline})
        load = subprocess.Popen(command, stdout=subprocess.PIPE, text=True)
        started = time.monotonic()
        samples = []
        while load.poll() is None:
            sample = process_tree_metrics(server.pid, time.monotonic() - started)
            samples.append(sample)
            append_progress(progress_output, {"event": "resource_sample", "metrics": sample})
            time.sleep(sample_interval)
        raw = load.communicate()[0]
        if load.returncode != 0:
            raise RuntimeError(f"oha failed with {load.returncode}")
        report = json.loads(raw)
        time.sleep(2)
        post_load = process_tree_metrics(server.pid, time.monotonic() - started)
        append_progress(progress_output, {"event": "post_load", "metrics": post_load})
        return {
            "oha": report,
            "warm_baseline": warm_baseline,
            "resource_samples": samples,
            "post_load": post_load,
        }
    finally:
        subprocess.run(
            ["kill", "-TERM", f"-{server.pid}"],
            check=False,
            capture_output=True,
        )
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            subprocess.run(["kill", "-KILL", f"-{server.pid}"], check=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("executable")
    parser.add_argument("--oha", default="oha")
    parser.add_argument("--duration", default="30s")
    parser.add_argument("--concurrency", type=int, default=64)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--sample-interval", type=float, default=1)
    parser.add_argument("--qps", type=int)
    parser.add_argument(
        "--architectures",
        nargs="+",
        choices=("processes",),
        default=("processes",),
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument("--progress-output", type=Path)
    args = parser.parse_args()

    result = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "duration": args.duration,
        "concurrency": args.concurrency,
        "qps": args.qps,
        "architectures": {},
    }
    if args.progress_output:
        args.progress_output.parent.mkdir(parents=True, exist_ok=True)
        args.progress_output.write_text("")
        append_progress(
            args.progress_output,
            {
                "event": "started",
                "generated_at": result["generated_at"],
                "duration": args.duration,
                "concurrency": args.concurrency,
                "qps": args.qps,
                "architectures": args.architectures,
            },
        )
    for architecture in args.architectures:
        runs = [
            run_once(
                args.executable,
                args.oha,
                architecture,
                args.duration,
                args.concurrency,
                args.sample_interval,
                args.qps,
                args.progress_output,
            )
            for _ in range(args.repeats)
        ]
        result["architectures"][architecture] = {"runs": runs}

    encoded = json.dumps(result, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded + "\n")
    print(encoded)


if __name__ == "__main__":
    main()
