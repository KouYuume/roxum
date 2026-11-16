#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
module=libraries/roc-protobuf/package/ProtobufScalar.roc
# roc test also executes expectations in imported ProtobufWire.
expected="$(grep -h '^expect' libraries/roc-protobuf/package/ProtobufWire.roc "$module" | wc -l | tr -d ' ')"
output="$("${ROC_BIN:-roc}" test "$module" 2>&1)" || { echo "$output" >&2; exit 1; }
echo "$output"
if [[ "$output" != *"All ($expected) tests passed"* ]]; then
    echo "expected $expected Protobuf tests" >&2
    exit 1
fi
python3 tests/protobuf/fuzz_oracle_test.py
