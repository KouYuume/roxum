#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
venv=zig-out/http2-listener/venv
if [[ ! -x "$venv/bin/python" ]]; then python3 -m venv "$venv"; fi
"$venv/bin/python" -m pip install --disable-pip-version-check --require-hashes --only-binary=:all: -r tests/http2-engine/requirements.txt
