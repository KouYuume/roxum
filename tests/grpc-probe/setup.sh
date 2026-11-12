#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
venv=zig-out/grpc-probe/venv
if [[ ! -x "$venv/bin/python" ]]; then python3 -m venv "$venv"; fi
"$venv/bin/python" -m pip install --disable-pip-version-check --require-hashes --only-binary=:all: -r tests/grpc-probe/requirements.txt
