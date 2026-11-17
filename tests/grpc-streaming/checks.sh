#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
venv=zig-out/grpc-streaming/venv
if [[ ! -x "$venv/bin/python" ]]; then python3 -m venv "$venv"; fi
"$venv/bin/python" -m pip install --disable-pip-version-check --require-hashes --only-binary=:all: -r tests/grpc-probe/requirements.txt -r tests/http2-engine/requirements.txt -r tools/protoc-gen-roc/requirements.txt -r tests/grpc-unary/requirements.txt
output=$("${ROC_BIN:-roc}" test integrations/roxum-grpc/package/main.roc 2>&1) || { echo "$output"; exit 1; }
echo "$output"
if ! echo "$output" | grep -Eq '^All \([1-9][0-9]*\) tests passed'; then exit 1; fi
python3 tools/protoc-gen-roc/setup.py
python3 tests/grpc-streaming/regenerate.py
zig-out/protobuf-codegen/venv/bin/python tests/grpc-unary/test_generator.py
"$venv/bin/python" -m grpc_tools.protoc -I tests/grpc-streaming --python_out=zig-out/grpc-streaming --grpc_python_out=zig-out/grpc-streaming tests/grpc-streaming/streaming.proto
