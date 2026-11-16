#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 tests/protobuf-codegen/test_schedule.py
python3 tools/protoc-gen-roc/setup.py
zig-out/protobuf-codegen/venv/bin/python tests/protobuf-codegen/test_generator.py
python3 tests/protobuf-codegen/regenerate.py
