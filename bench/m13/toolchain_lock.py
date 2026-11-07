#!/usr/bin/env python3
"""Freeze or verify the native Linux benchmark toolchain before building."""
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess

TOOLS = {'roc': ['version'], 'zig': ['version'], 'rustc': ['-vV'],
         'cargo': ['--version'], 'go': ['version']}
ENV = ('RUSTFLAGS', 'RUSTUP_TOOLCHAIN', 'GOFLAGS', 'GOAMD64', 'GOARM64', 'CC', 'CFLAGS', 'LDFLAGS')


def current():
    return {'schema_version': 1, 'os': platform.system(), 'architecture': platform.machine(),
            'versions': {name: subprocess.check_output([name, *args], text=True).strip()
                         for name, args in TOOLS.items()},
            'environment': {name: os.environ.get(name) for name in ENV}}


def verify(expected, actual):
    if expected != actual:
        changed = [key for key in sorted(set(expected) | set(actual)) if expected.get(key) != actual.get(key)]
        raise ValueError('toolchain lock mismatch: ' + ', '.join(changed))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['freeze', 'check'])
    parser.add_argument('lock', type=Path)
    args = parser.parse_args()
    actual = current()
    if actual['os'] != 'Linux':
        parser.error('this lock is for native Linux comparison builds')
    if args.action == 'freeze':
        with args.lock.open('x') as output:
            output.write(json.dumps(actual, indent=2) + '\n')
    else:
        verify(json.loads(args.lock.read_text()), actual)


if __name__ == '__main__':
    main()
