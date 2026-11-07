"""Helpers for tests that start a roxum server process.

A server prints its port on stdout once every worker is ready. Reading that
line, and stopping the server afterwards, must not hang a test run when the
server fails: a test should report the failure and leave no process behind.
"""
import os
import sys
import select
import signal
import subprocess

PORT_TIMEOUT_SECONDS = 30
STOP_TIMEOUT_SECONDS = 6


def read_port(process, timeout=PORT_TIMEOUT_SECONDS):
    """Returns the port the server printed, or raises when it prints nothing
    within `timeout` seconds or exits first."""
    ready, _, _ = select.select([process.stdout], [], [], timeout)
    if not ready:
        raise RuntimeError(f"server printed no port within {timeout} s")
    line = process.stdout.readline().strip()
    if not line:
        raise RuntimeError(f"server exited before printing a port (status {process.poll()})")
    return int(line)


def stop(process, timeout=STOP_TIMEOUT_SECONDS):
    """Stops the server's process group with SIGTERM and returns its exit
    status. If it does not exit in time, kills the group and raises, so a
    stuck server neither hides the failure nor outlives the test."""
    if process.poll() is not None:
        return process.returncode
    os.killpg(process.pid, signal.SIGTERM)
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=timeout)
        raise RuntimeError(f"server did not stop within {timeout} s of SIGTERM")


def children(parent):
    """The process IDs whose parent is `parent`."""
    output = subprocess.run(
        ["ps", "-axo", "pid=,ppid="],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [int(pid) for pid, ppid in (line.split() for line in output.splitlines()) if int(ppid) == parent]


def cgroup_cpu_limit():
    """The cgroup v2 CPU limit in whole CPUs, rounded up, or None."""
    try:
        with open("/sys/fs/cgroup/cpu.max") as file:
            fields = file.read().split()
    except OSError:
        return None
    if len(fields) != 2 or fields[0] == "max":
        return None
    try:
        quota, period = int(fields[0]), int(fields[1])
    except ValueError:
        return None
    if quota <= 0 or period <= 0:
        return None
    return -(-quota // period)


def expected_thread_count():
    """The number of threads `Server.Threads.Auto` runs: one per CPU the
    process may run on (1 to 256). On Linux the host counts the CPUs in its
    affinity mask, which can be fewer than `os.cpu_count()` in a container,
    and a cgroup CPU limit lowers the count further."""
    if hasattr(os, "sched_getaffinity"):
        cpus = len(os.sched_getaffinity(0))
    else:
        cpus = os.cpu_count() or 1
    limit = cgroup_cpu_limit() if sys.platform.startswith("linux") else None
    if limit is not None:
        cpus = min(cpus, limit)
    return min(max(cpus, 1), 256)


def ready_workers(server):
    """The server's worker process IDs. Call it after `read_port`: the
    supervisor prints the port only once every worker is ready, so no worker
    is still starting. Raises when the server has exited or runs no worker."""
    if server.poll() is not None:
        raise RuntimeError(f"server exited after printing its port (status {server.returncode})")
    workers = children(server.pid)
    if not workers:
        raise RuntimeError("server runs no worker")
    return workers
