"""Sample the server process tree, including its root, on Linux and macOS.

Summed RSS counts shared pages once per process; it is not unique physical memory.
Use cgroup accounting for the eventual Linux resource-budget comparison.
"""
import subprocess
import threading
import time


def select_tree(rows, root):
    selected = {root} if root in rows else set()
    while True:
        children = {pid for pid, row in rows.items() if row["ppid"] in selected}
        expanded = selected | children
        if expanded == selected:
            return [{"pid": pid, **rows[pid]} for pid in sorted(selected)]
        selected = expanded


def snapshot(root):
    output = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,rss="], text=True, timeout=5)
    rows = {}
    for line in output.splitlines():
        pid, ppid, rss = map(int, line.split())
        rows[pid] = {"ppid": ppid, "rss_kib": rss}
    return select_tree(rows, root)


class ProcessSampler:
    def __init__(self, root, interval=1.0):
        self.root = root
        self.interval = interval
        self.samples = []
        self.errors = []
        self.stop_event = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self.started = time.monotonic()
        self.thread.start()

    def _run(self):
        while not self.stop_event.is_set():
            try:
                processes = snapshot(self.root)
                if not processes:
                    raise RuntimeError("server root missing from process snapshot")
                self.samples.append({"seconds": time.monotonic() - self.started,
                                     "processes": processes,
                                     "summed_rss_kib": sum(p["rss_kib"] for p in processes)})
            except Exception as error:
                self.errors.append(f"{type(error).__name__}: {error}")
            self.stop_event.wait(self.interval)

    def stop(self):
        self.stop_event.set()
        self.thread.join(timeout=7)
        if self.thread.is_alive():
            self.errors.append("process sampler did not stop")
        return {"kind": "sampled-process-tree-rss", "interval_seconds": self.interval,
                "includes_root": True, "shared_pages_counted_per_process": True,
                "valid": bool(self.samples) and not self.errors,
                "samples": self.samples, "errors": self.errors,
                "sampled_peak_summed_rss_kib": max(
                    (row["summed_rss_kib"] for row in self.samples), default=None)}
