#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
python3 tools/protoc-gen-roc/setup.py
venv=zig-out/grpc-example/venv
if [[ ! -x "$venv/bin/python" ]]; then python3 -m venv "$venv"; fi
"$venv/bin/python" -m pip install --disable-pip-version-check --require-hashes --only-binary=:all: -r integrations/roxum-grpc/example/requirements.txt
"$venv/bin/python" integrations/roxum-grpc/example/generate.py --check
"$venv/bin/python" integrations/roxum-grpc/example/test_generate.py
