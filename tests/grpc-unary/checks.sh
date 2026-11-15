#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
venv=zig-out/grpc-unary/venv
if [[ ! -x "$venv/bin/python" ]]; then python3 -m venv "$venv"; fi
"$venv/bin/python" -m pip install --disable-pip-version-check --require-hashes --only-binary=:all: -r tests/grpc-probe/requirements.txt -r tools/protoc-gen-roc/requirements.txt
output=$("${ROC_BIN:-roc}" test integrations/roxum-grpc/package/main.roc 2>&1) || { echo "$output"; exit 1; }
echo "$output"
# The pinned compiler can exit zero after failed expectations.
if ! echo "$output" | grep -Eq '^All \([1-9][0-9]*\) tests passed'; then exit 1; fi

python3 tools/protoc-gen-roc/setup.py
python3 tests/grpc-unary/regenerate.py

zig-out/protobuf-codegen/venv/bin/python tests/grpc-unary/test_generator.py
