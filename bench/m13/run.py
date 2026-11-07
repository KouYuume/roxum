#!/usr/bin/env python3
"""Local HTTP diagnostics; see protocol.md before making performance claims.

Usage: run.py [--runs N] [--seconds N] [--warmup-seconds N]
              [--scenario NAME] OHA OUTPUT.json name=executable ...

All trials, including failures, are retained. Server and client share a machine.
The helpers are also used by the router/body regression experiments.
"""
import argparse
import hashlib
import http.client
import json
import math
import os
from pathlib import Path
import platform
import resource
import shutil
import selectors
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

sys.path.insert(0, str(Path(__file__).resolve().parent))
from process_metrics import ProcessSampler

DURATION = "30s"
BODY = b"x" * (32 * 1024)
SCENARIOS = [
    ("plaintext", "GET", "/plaintext", 64, None),
    ("json", "GET", "/json", 64, None),
    ("routing", "GET", "/r57/items/42", 64, None),
    ("large-body", "POST", "/echo", 64, BODY),
    ("keep-alive-heavy", "GET", "/plaintext", 16, None),
    ("many-connections", "GET", "/plaintext", 1000, None),
]
ROOT = Path(__file__).resolve().parents[2]


def stop_server(server):
    try:
        os.killpg(server.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        server.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(server.pid, signal.SIGKILL)
        server.wait(timeout=5)
    log = getattr(server, "bench_log", None)
    if log is None:
        return ""
    log.seek(0)
    text = log.read()
    log.close()
    server.stdout.close()
    return text


def run_server(executable):
    log = tempfile.TemporaryFile(mode="w+")
    try:
        server = subprocess.Popen([executable], stdout=subprocess.PIPE, stderr=log,
                                  text=True, start_new_session=True)
    except BaseException:
        log.close()
        raise
    server.bench_log = log
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(server.stdout, selectors.EVENT_READ)
            if not selector.select(20):
                raise TimeoutError("server did not publish a port within 20 seconds")
        port = int(server.stdout.readline().strip())
        if not 1 <= port <= 65535:
            raise ValueError("server published an invalid port")
        return server, port
    except BaseException as error:
        logs = stop_server(server)
        raise RuntimeError(f"server startup failed: {error}\n{logs}") from error


def validate_response(port, method, path, body, host="127.0.0.1"):
    if path == "/plaintext":
        expected, media_type = b"Hello, World!", "text/plain"
    elif path == "/json":
        expected, media_type = b'{"message":"Hello, World!"}', "application/json"
    elif path == "/echo":
        expected, media_type = body, "application/octet-stream"
    elif path.startswith("/r") and "/items/" in path:
        expected, media_type = path.rsplit("/", 1)[1].encode(), "text/plain"
    else:
        raise ValueError(f"no response contract for {path}")
    connection = http.client.HTTPConnection(host, port, timeout=10)
    try:
        connection.request(method, path, body=body)
        response = connection.getresponse()
        received = response.read(len(expected) + 1)
        actual_type = (response.getheader("content-type") or "").split(";", 1)[0].strip().lower()
        if response.status != 200 or received != expected or actual_type != media_type:
            raise ValueError(f"response contract failed for {path}: status={response.status}, "
                             f"media_type={actual_type}, body_matches={received == expected}")
    finally:
        connection.close()


def load_result(raw):
    summary = raw["summary"]
    percentiles = raw["latencyPercentiles"]
    status = raw.get("statusCodeDistribution") or {}
    errors = raw.get("errorDistribution") or {}
    reasons = []
    if not status or set(status) != {"200"} or sum(status.values()) <= 0:
        reasons.append("expected positive completed requests with only status 200")
    if any(errors.values()):
        reasons.append("load generator reported errors")
    if summary["successRate"] != 1:
        reasons.append("success rate is not 100%")
    latencies = [percentiles["p50"], percentiles["p99"], summary["slowest"]]
    if any(not math.isfinite(value) or value < 0 for value in latencies):
        reasons.append("latencies must be finite and nonnegative")
    elif latencies != sorted(latencies):
        reasons.append("latencies must satisfy p50 <= p99 <= maximum")
    rps = summary["requestsPerSec"]
    if not math.isfinite(rps) or rps <= 0:
        reasons.append("throughput must be finite and positive")
    return {
        "rps": rps, "success_rate": summary["successRate"],
        "p50_ms": percentiles["p50"] * 1000,
        "p99_ms": percentiles["p99"] * 1000,
        "max_ms": summary["slowest"] * 1000,
        "status": status, "errors": errors, "valid": not reasons,
        "invalid_reasons": reasons, "raw": raw,
    }


def reject_constant(value):
    raise ValueError(f"non-finite JSON number: {value}")


def run_oha(oha, port, method, path, connections, body, duration=None, host="127.0.0.1", rate=None):
    duration = duration or DURATION
    command = [oha, "-z", duration, "-w", "-t", "10s", "--http-version", "1.1",
               "-c", str(connections), "--no-tui", "--output-format", "json", "-m", method]
    if rate is not None:
        if type(rate) is not int or rate <= 0:
            raise ValueError('rate must be a positive integer')
        command += ['-q', str(rate), '--latency-correction']
    with tempfile.TemporaryDirectory(prefix="roxum-http-bench-") as directory:
        if body is not None:
            body_file = Path(directory) / "body"
            body_file.write_bytes(body)
            command += ["-D", str(body_file)]
        command.append(f"http://{host}:{port}{path}")
        timing = {"clock": "client_monotonic_ns",
                  "spawn_begin_ns": time.monotonic_ns(),
                  "active_traffic_begin_ns": None, "active_traffic_end_ns": None,
                  "limitation": "oha JSON does not expose traffic/drain/output phase timestamps"}
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
            timing["spawn_returned_ns"] = time.monotonic_ns()
            try:
                stdout, stderr = process.communicate(timeout=float(duration.removesuffix("s")) + 30)
            except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
                process.kill()
                stdout, stderr = process.communicate()
                timing["output_collected_ns"] = time.monotonic_ns()
                interrupted = isinstance(error, KeyboardInterrupt)
                return {"valid": False, "interrupted": interrupted,
                        "invalid_reasons": ["load interrupted" if interrupted else "load generator exceeded its deadline"],
                        "command": command, "stdout": stdout, "stderr": stderr,
                        "exit_code": process.returncode, "timing": timing}
            timing["output_collected_ns"] = time.monotonic_ns()
            completed = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    record = {"command": command, "exit_code": completed.returncode,
              "stdout": completed.stdout, "stderr": completed.stderr, "timing": timing}
    try:
        record.update(load_result(json.loads(completed.stdout, parse_constant=reject_constant)))
        if completed.returncode:
            record["invalid_reasons"].append("load generator exited unsuccessfully")
            record["valid"] = False
        if rate is not None:
            record['offered_load'] = {'target_rps': rate, 'latency_correction': True,
                                     'minimum_target_fraction': 0.99,
                                     'target_met': record['rps'] >= rate * 0.99}
    except (ValueError, KeyError, TypeError) as error:
        record.update(valid=False, invalid_reasons=[f"invalid load-tool output: {error}"])
    timing["parse_finished_ns"] = time.monotonic_ns()
    return record


def measure(oha, executable, method, path, connections, body, warmup="5s"):
    record = {"valid": False, "started_at": datetime.now(timezone.utc).isoformat(),
              "load_average": os.getloadavg()}
    server = None
    sampler = None
    try:
        server, port = run_server(executable)
        validate_response(port, method, path, body)
        record["warmup"] = run_oha(oha, port, method, path, connections, body, warmup)
        if not record["warmup"]["valid"]:
            record["invalid_reasons"] = ["warmup failed"]
        else:
            sampler = ProcessSampler(server.pid)
            sampler.start()
            record.update(run_oha(oha, port, method, path, connections, body))
            validate_response(port, method, path, body)
            if server.poll() is not None:
                raise RuntimeError("server exited during measurement")
    except Exception as error:
        record.update(valid=False, exception=f"{type(error).__name__}: {error}")
    finally:
        if sampler is not None:
            record["process_metrics"] = sampler.stop()
        if server is not None:
            record["server_stderr"] = stop_server(server)
            record["server_exit_code"] = server.returncode
        record["finished_at"] = datetime.now(timezone.utc).isoformat()
    return record


def median_run(runs):
    if not runs or any(not run.get("valid", False) for run in runs):
        raise ValueError("cannot summarize an empty or invalid trial set")
    middle = statistics.median_low(run["rps"] for run in runs)
    return next(run for run in runs if run["rps"] == middle)


def build_provenance(executable):
    path = Path(executable)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    matching = []
    for candidate in sorted(path.parent.glob("build-manifest-*.json")):
        manifest = json.loads(candidate.read_text())
        if manifest.get("binaries", {}).get(path.name) == digest:
            matching.append({"path": str(candidate), "manifest": manifest})
    return {"executable": str(path), "sha256": digest, "build_provenance": matching}


def command_output(command):
    try:
        return subprocess.check_output(command, cwd=ROOT, text=True, stderr=subprocess.STDOUT,
                                       timeout=10).strip()
    except (OSError, subprocess.SubprocessError) as error:
        return f"unavailable: {error}"


def positive(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def save(output, result):
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    temporary.replace(output)


def main():
    global DURATION
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=positive, default=6)
    parser.add_argument("--seconds", type=positive, default=30)
    parser.add_argument("--warmup-seconds", type=positive, default=5)
    parser.add_argument("--scenario", action="append", choices=[row[0] for row in SCENARIOS])
    parser.add_argument("oha")
    parser.add_argument("output", type=Path)
    parser.add_argument("servers", nargs="+")
    args = parser.parse_args()
    servers = []
    for argument in args.servers:
        name, separator, executable = argument.partition("=")
        if not name or not separator or not Path(executable).is_file():
            parser.error("servers must be name=existing-executable")
        if name in dict(servers):
            parser.error("server names must be unique")
        servers.append((name, str(Path(executable).resolve())))
    if args.output.exists():
        parser.error("output already exists; use a new path to retain prior trials")
    DURATION = f"{args.seconds}s"
    result = {"schema_version": 2, "kind": "local-diagnostic", "comparison_valid": False,
              "date": datetime.now(timezone.utc).isoformat(), "machine": platform.platform(),
              "cpus": os.cpu_count(), "architecture": platform.machine(),
              "file_descriptor_limits": resource.getrlimit(resource.RLIMIT_NOFILE),
              "cpu_affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
              "runtime_environment": {key: os.environ.get(key) for key in
                                      ("GOMAXPROCS", "GOMEMLIMIT", "GOGC", "TOKIO_WORKER_THREADS")},
              "duration": DURATION, "runs": args.runs,
              "balanced_order": args.runs % len(servers) == 0,
              "warmup_seconds": args.warmup_seconds,
              "revision": command_output(["git", "rev-parse", "HEAD"]),
              "working_tree": command_output(["git", "status", "--porcelain"]),
              "tracked_patch": command_output(["git", "diff", "HEAD", "--", "bench/m13", "platform"]),
              "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "oha_sha256": hashlib.sha256(Path(shutil.which(args.oha) or args.oha).read_bytes()).hexdigest(),
              "oha_version": command_output([args.oha, "--version"]),
              "servers": {name: build_provenance(exe) for name, exe in servers}, "scenarios": {}, "samples": []}
    if not result["balanced_order"]:
        print("warning: repetitions are not a multiple of candidate count; order positions are unbalanced",
              file=sys.stderr)
    save(args.output, result)
    for scenario, method, path, connections, body in SCENARIOS:
        if args.scenario and scenario not in args.scenario:
            continue
        runs = {name: [] for name, _ in servers}
        for index in range(args.runs):
            order = servers[index % len(servers):] + servers[:index % len(servers)]
            for name, executable in order:
                row = measure(args.oha, executable, method, path, connections, body,
                              warmup=f"{args.warmup_seconds}s")
                row.update(server=name, scenario=scenario, repetition=index,
                           method=method, path=path, connections=connections,
                           body_bytes=len(body) if body is not None else 0)
                result["samples"].append(row)
                runs[name].append(row)
                save(args.output, result)
                print(f"{scenario} {name} trial={index} valid={row['valid']}", flush=True)
        # Never turn a failed comparison into a ranking of surviving trials.
        if all(row["valid"] for rows in runs.values() for row in rows):
            result["scenarios"][scenario] = {
                name: {key: median_run(rows)[key] for key in ("rps", "p50_ms", "p99_ms", "max_ms")}
                for name, rows in runs.items()}
            for name, rows in runs.items():
                result["scenarios"][scenario][name].update(
                    rps_runs=[row["rps"] for row in rows],
                    rps_min=min(row["rps"] for row in rows), rps_max=max(row["rps"] for row in rows))
        save(args.output, result)
    result["comparison_valid"] = all(row["valid"] for row in result["samples"])
    if not result["comparison_valid"]:
        result["scenarios"] = {}
    result["finished_at"] = datetime.now(timezone.utc).isoformat()
    save(args.output, result)
    return 0 if result["comparison_valid"] else 1


if __name__ == "__main__":
    sys.exit(main())
