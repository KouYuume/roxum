#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
module=libraries/roc-protobuf/package/ProtobufWire.roc
expected="$(grep -c '^expect' "$module")"
output="$("${ROC_BIN:-roc}" test "$module" 2>&1)" || { echo "$output" >&2; exit 1; }
echo "$output"
if [[ "$output" != *"All ($expected) tests passed"* ]]; then
    echo "expected $expected Protobuf wire tests" >&2
    exit 1
fi
