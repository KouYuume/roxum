#!/usr/bin/env python3
"""Run on the load-generator host; control commands manage the separate server.

Control commands are explicit argv arrays in an experiment JSON, never shell text.
Each must emit one JSON object. See remote.md for the transport contract.
"""
import argparse
import ipaddress
import json
from pathlib import Path
import subprocess
import time
from datetime import datetime, timezone

import run as bench
from linux_server import cpu_list
from client_metrics import ClientSampler


def control(argv, records):
    if not isinstance(argv, list) or not argv or any(not isinstance(x, str) for x in argv):
        raise ValueError("control command must be a nonempty argv array")
    begin = time.monotonic_ns()
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=300)
    except subprocess.TimeoutExpired as error:
        def decoded(value):
            return value.decode(errors="replace") if isinstance(value, bytes) else (value or "")
        records.append({"argv": argv, "exit_code": None, "timeout": True,
                        "begin_monotonic_ns": begin, "end_monotonic_ns": time.monotonic_ns(),
                        "stdout": decoded(error.stdout), "stderr": decoded(error.stderr)})
        raise
    records.append({"argv": argv, "exit_code": result.returncode,
                    "begin_monotonic_ns": begin, "end_monotonic_ns": time.monotonic_ns(),
                    "stdout": result.stdout, "stderr": result.stderr})
    if result.returncode:
        raise RuntimeError("control command failed; see control records")
    return json.loads(result.stdout)


def check_resources(snapshot, budget):
    group = snapshot["cgroup"]
    if snapshot["ActiveState"] != "active":
        raise ValueError("server is not active")
    if cpu_list(group["cpuset.cpus.effective"].strip()) != cpu_list(budget["cpus"]):
        raise ValueError("effective CPU set differs from experiment budget")
    quota, period = map(int, group["cpu.max"].split())
    if quota != period * len(cpu_list(budget["cpus"])):
        raise ValueError("effective CPU quota differs from experiment budget")
    if int(group["memory.max"]) != budget["memory_bytes"] or int(group["memory.swap.max"]) != 0:
        raise ValueError("effective memory limits differ from experiment budget")
    events = dict(line.split() for line in group["memory.events"].splitlines())
    if any(int(events.get(key, 0)) for key in ("oom", "oom_kill", "oom_group_kill")):
        raise ValueError("server cgroup reported an OOM event")


def trial(config, candidate, scenario, oha, seconds, warmup, rate=None):
    _, method, path, connections, body = scenario
    row = {"valid": False, "control": [], "started_at": datetime.now(timezone.utc).isoformat()}
    host, port = config["host"], config["port"]
    sampler = None
    try:
        row["start"] = control(candidate["start"], row["control"])
        deadline = time.monotonic() + 20
        while True:
            try:
                bench.validate_response(port, method, path, body, host=host)
                break
            except (OSError, ValueError):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.1)
        row["warmup"] = bench.run_oha(oha, port, method, path, connections, body,
                                       f"{warmup}s", host=host, rate=rate)
        if not row["warmup"]["valid"]:
            if row['warmup'].get('interrupted'):
                row['interrupted'] = True
            raise ValueError("warmup failed")
        row["before"] = control(config["snapshot"], row["control"])
        check_resources(row["before"], config["budget"])
        sampler = ClientSampler()
        sampler.start()
        row.update(bench.run_oha(oha, port, method, path, connections, body,
                                f"{seconds}s", host=host, rate=rate))
        row["client_metrics"] = sampler.stop()
        sampler = None
        bench.validate_response(port, method, path, body, host=host)
        row["after"] = control(config["snapshot"], row["control"])
        check_resources(row["after"], config["budget"])
        if not row["before"].get("InvocationID") or row["before"]["InvocationID"] != row["after"].get("InvocationID"):
            raise ValueError("server invocation changed during measurement")
    except KeyboardInterrupt:
        row.update(valid=False, interrupted=True, exception='KeyboardInterrupt')
    except Exception as error:
        row.update(valid=False, exception=f"{type(error).__name__}: {error}")
    finally:
        if sampler is not None:
            row["client_metrics"] = sampler.stop()
        try:
            row["stop"] = control(config["stop"], row["control"])
            if row["stop"].get("stopped") is not True:
                raise ValueError("controller did not confirm stop")
        except Exception as error:
            row.update(valid=False, cleanup_error=f"{type(error).__name__}: {error}")
        row["finished_at"] = datetime.now(timezone.utc).isoformat()
    return row


def check_measurement(config, args):
    expected = config.get('measurement')
    if expected is None:
        return
    actual = {'runs': args.runs, 'seconds': args.seconds, 'warmup_seconds': args.warmup_seconds,
              'scenarios': [row[0] for row in bench.SCENARIOS
                            if not args.scenario or row[0] in args.scenario]}
    if getattr(args, 'rate', None) is not None or 'rate' in expected:
        actual['rate'] = getattr(args, 'rate', None)
    if expected != actual:
        raise ValueError(f'measurement differs from frozen configuration: expected {expected}, got {actual}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--oha", default="oha")
    parser.add_argument("--runs", type=bench.positive, default=6)
    parser.add_argument("--seconds", type=bench.positive, default=30)
    parser.add_argument("--warmup-seconds", type=bench.positive, default=5)
    parser.add_argument("--scenario", action="append", choices=[s[0] for s in bench.SCENARIOS])
    parser.add_argument('--rate', type=bench.positive, help='global requests/s with coordinated-omission correction')
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    try:
        check_measurement(config, args)
    except ValueError as error:
        parser.error(str(error))
    ipaddress.IPv4Address(config["host"])
    if type(config["port"]) is not int or not 1 <= config["port"] <= 65535:
        parser.error("port must be in 1..65535")
    candidates = config["candidates"]
    if not candidates or len({c["name"] for c in candidates}) != len(candidates):
        parser.error("candidates must have unique names")
    if args.output.exists():
        parser.error("output already exists")
    result = {"kind": "remote-diagnostic", "schema_version": 1, "config": config,
              "runs": args.runs, "seconds": args.seconds, "warmup_seconds": args.warmup_seconds,
              "rate": args.rate,
              "balanced_order": args.runs % len(candidates) == 0, "comparison_valid": False,
              "client": {"platform": bench.platform.platform(), "cpus": bench.os.cpu_count(),
                         "oha_version": bench.command_output([args.oha, "--version"])},
              "samples": []}
    bench.save(args.output, result)
    for scenario in bench.SCENARIOS:
        if args.scenario and scenario[0] not in args.scenario:
            continue
        for repetition in range(args.runs):
            offset = repetition % len(candidates)
            for candidate in candidates[offset:] + candidates[:offset]:
                row = trial(config, candidate, scenario, args.oha, args.seconds, args.warmup_seconds, args.rate)
                row.update(server=candidate["name"], scenario=scenario[0], repetition=repetition)
                result["samples"].append(row)
                bench.save(args.output, result)
                print(f"{scenario[0]} {candidate['name']} valid={row['valid']}", flush=True)
                if row.get('interrupted'):
                    return 130
                if row.get("cleanup_error"):
                    return 1  # A leftover server makes subsequent trials unsafe and ambiguous.
    result["comparison_valid"] = all(row["valid"] for row in result["samples"])
    bench.save(args.output, result)
    return 0 if result["comparison_valid"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
