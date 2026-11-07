#!/usr/bin/env python3
"""M23d: the sizes of the binaries bench/m13/compile.py built.

    bench/m13/sizes.py <binaries dir> <output.json>

For each binary: its size as built, its size after `strip` (on a copy),
and how it is linked (`file`).
"""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    binaries, output = Path(sys.argv[1]), Path(sys.argv[2])
    sizes = {}
    with tempfile.TemporaryDirectory() as directory:
        for binary in sorted(path for path in binaries.iterdir() if path.is_file()):
            stripped = Path(directory) / binary.name
            shutil.copy(binary, stripped)
            subprocess.run(["strip", str(stripped)], check=True)
            kind = subprocess.run(["file", "-b", str(binary)], capture_output=True, text=True, check=True).stdout.strip()
            sizes[binary.name] = {"bytes": binary.stat().st_size, "stripped_bytes": stripped.stat().st_size, "file": kind}
            print(f"{binary.name:20} {binary.stat().st_size:>10} {stripped.stat().st_size:>10}  {kind[:60]}")
    output.write_text(json.dumps(sizes, indent=2) + "\n")


if __name__ == "__main__":
    main()
