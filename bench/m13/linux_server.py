#!/usr/bin/env python3
"""Control one benchmark server in a transient systemd service (cgroup v2)."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

from run import build_provenance
import network_metrics

UNIT = "roxum-http-benchmark.service"


def command(argv):
    return subprocess.check_output(argv, text=True, timeout=30).strip()


def cpu_list(value):
    if not re.fullmatch(r"\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*", value):
        raise ValueError("cpus must be a comma-separated CPU list")
    cpus = set()
    for part in value.split(","):
        bounds = [int(n) for n in part.split("-")]
        first, last = bounds[0], bounds[-1]
        if last < first or last > 65535:
            raise ValueError("invalid CPU range")
        cpus.update(range(first, last + 1))
    return cpus


def start_command(config):
    cpus = cpu_list(config["cpus"])
    memory = config["memory_bytes"]
    if type(memory) is not int or memory < 1:
        raise ValueError("memory_bytes must be a positive integer")
    for key in ("executable", "working_directory"):
        if not Path(config[key]).is_absolute():
            raise ValueError(f"{key} must be absolute")
    user = config["user"]
    if not re.fullmatch(r"[a-z_][a-z0-9_-]*", user) or user == "root":
        raise ValueError("choose an unprivileged service user")
    return ["systemd-run", f"--unit={UNIT}", "--service-type=exec",
            f"--uid={user}", f"--working-directory={config['working_directory']}",
            "--property=CPUAccounting=yes", "--property=MemoryAccounting=yes",
            "--property=AllowedCPUs=" + " ".join(str(cpu) for cpu in sorted(cpus)),
            f"--property=CPUQuota={len(cpus) * 100}%",
            f"--property=MemoryMax={memory}", "--property=MemorySwapMax=0",
            "--property=LimitNOFILE=65536", "--property=TasksMax=4096",
            "--property=KillMode=control-group", "--property=TimeoutStopSec=10s",
            "--property=RuntimeMaxSec=600", "--property=NoNewPrivileges=yes",
            "--", config["executable"]]


def snapshot():
    begin = time.monotonic_ns()
    properties = command(["systemctl", "show", UNIT,
                          "--property=ActiveState,SubState,Result,MainPID,ControlGroup,InvocationID,"
                          "CPUUsageNSec,MemoryCurrent,MemoryPeak,AllowedCPUs,CPUQuotaPerSecUSec,"
                          "MemoryMax,MemorySwapMax,TasksMax,LimitNOFILE"])
    values = dict(line.split("=", 1) for line in properties.splitlines() if "=" in line)
    group = values.get("ControlGroup", "")
    if not group.startswith("/") or ".." in Path(group).parts:
        raise RuntimeError("service has no valid cgroup")
    directory = Path("/sys/fs/cgroup") / group.lstrip("/")
    values["cgroup"] = {name: (directory / name).read_text() for name in
                        ("cpu.max", "cpu.stat", "cpuset.cpus.effective", "memory.max",
                         "memory.current", "memory.events", "memory.swap.max")}
    values["network_limits"] = network_metrics.snapshot()
    values["timing"] = {"clock": "server_monotonic_ns", "begin_ns": begin,
                        "end_ns": time.monotonic_ns()}
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["start", "snapshot", "stop"])
    parser.add_argument("config", type=Path, nargs="?")
    args = parser.parse_args()
    if os.geteuid() != 0 or not Path("/sys/fs/cgroup/cgroup.controllers").exists():
        parser.error("requires root on Linux with cgroup v2 and systemd")
    if args.action == "start":
        if args.config is None:
            parser.error("start requires a JSON config")
        config = json.loads(args.config.read_text())
        argv = start_command(config)
        available = os.sched_getaffinity(0)
        if not cpu_list(config["cpus"]) <= available:
            parser.error("requested CPUs are outside the available CPU set")
        command(argv)
        result = snapshot()
        result["start_command"] = argv
        result["config"] = config
        result["binary"] = build_provenance(config["executable"])
        result["cpu_topology"] = command(["lscpu", "--json"])
        result["kernel"] = command(["uname", "-a"])
    elif args.action == "snapshot":
        result = snapshot()
    else:
        invocation = command(["systemctl", "show", UNIT, "--property=InvocationID", "--value"])
        command(["systemctl", "stop", UNIT])
        logs = command(["journalctl", f"_SYSTEMD_INVOCATION_ID={invocation}", "--no-pager", "-o", "short-iso"])
        subprocess.run(["systemctl", "reset-failed", UNIT], capture_output=True, timeout=30)
        result = {"stopped": True, "logs": logs}
    print(json.dumps(result))


if __name__ == "__main__":
    main()
