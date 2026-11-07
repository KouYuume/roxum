#!/usr/bin/env python3
"""Run a compiler fixture with a portable wall-clock timeout."""

from __future__ import annotations

import subprocess
import sys


try:
    completed = subprocess.run(
        sys.argv[1:],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=30,
        check=False,
    )
except subprocess.TimeoutExpired as error:
    if error.stdout:
        print(error.stdout, end="")
    raise SystemExit(124)

print(completed.stdout, end="")
raise SystemExit(completed.returncode)
