#!/usr/bin/env python3
"""Compare the observed echo allocation sequence on Zig 0.16.0 allocators.

Usage: python3 bench/m13/allocator-replay.py OUTPUT.json
Builds isolated copies with the stock SMP allocator, PageAllocator, and an
experimental SMP change that searches every CPU slot before mapping a slab.
The installed Zig library and roxum production sources are never modified.
RSS is sampled after every allocation in an iteration has been freed.
"""
import json
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile


def sample(executable):
    process = subprocess.Popen([str(executable)], stderr=subprocess.PIPE, text=True)
    samples = []
    try:
        for line in process.stderr:
            if not line.startswith("ITER "):
                raise RuntimeError(line.rstrip())
            if sys.platform.startswith("linux"):
                status = Path(f"/proc/{process.pid}/status").read_text().splitlines()
                rss = next(int(row.split()[1]) for row in status if row.startswith("VmRSS:"))
            else:
                rss = int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(process.pid)], text=True))
            samples.append({"iterations": int(line.split()[1]), "rss_kib": rss})
        if process.wait(timeout=10) != 0:
            raise RuntimeError(f"Replay exited with {process.returncode}")
        if [row["iterations"] for row in samples] != [1, 100, 1000, 5000]:
            raise RuntimeError(f"Incomplete samples: {samples}")
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    return samples


def compare():
    version = subprocess.check_output(["zig", "version"], text=True).strip()
    if version != "0.16.0":
        raise RuntimeError(f"This reproduction targets Zig 0.16.0; found {version}")
    environment = subprocess.check_output(["zig", "env"], text=True)
    library = Path(re.search(r'\.lib_dir = "([^"\n]+)"', environment).group(1))
    original = (library / "std/heap/SmpAllocator.zig").read_text()
    old_search = "search_count >= max_alloc_search"
    if original.count(old_search) != 1:
        raise RuntimeError("SMP source does not match the expected search condition")
    modified = original.replace('@import("../std.zig")', '@import("std")')
    modified = modified.replace(old_search, "search_count >= getCpuCount() - 1")
    source = Path(__file__).with_suffix(".zig").read_text()
    variants = {
        "smp": "std.heap.smp_allocator",
        "page": "std.heap.page_allocator",
        "search_all": 'std.mem.Allocator{ .ptr = undefined, .vtable = &@import("smp_search.zig").vtable }',
    }
    result = {"zig": version, "machine": platform.platform(), "samples": {}}
    with tempfile.TemporaryDirectory(prefix="roxum-allocator-replay-") as directory:
        stage = Path(directory)
        (stage / "smp_search.zig").write_text(modified)
        for name, allocator in variants.items():
            program = stage / f"{name}.zig"
            program.write_text(source.replace("std.heap.smp_allocator", allocator))
            executable = stage / name
            subprocess.run(["zig", "build-exe", "-O", "ReleaseSafe", "-lc",
                            f"-femit-bin={executable}", str(program)], check=True)
            result["samples"][name] = sample(executable)
    return result


if __name__ == "__main__":
    if not (sys.platform.startswith("linux") or sys.platform == "darwin"):
        raise SystemExit("RSS sampling supports Linux and macOS")
    Path(sys.argv[1]).write_text(json.dumps(compare(), indent=2) + "\n")
