#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/roxum-abi-mismatch.XXXXXX")"
trap 'rm -rf -- "$temporary_dir"' EXIT

source_glue="$script_dir/generated/roc_platform_abi.zig"
mismatched_glue="$temporary_dir/roc_platform_abi.zig"

python3 - "$source_glue" "$mismatched_glue" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
old = '''pub const AbiChoiceTag = enum(u8) {
    @"Byte" = 0,
    @"Empty" = 1,'''
new = '''pub const AbiChoiceTag = enum(u8) {
    @"Byte" = 1,
    @"Empty" = 0,'''
if source.count(old) != 1:
    raise SystemExit("generated AbiChoiceTag layout did not match the negative fixture")
Path(sys.argv[2]).write_text(source.replace(old, new))
PY

ABI_GLUE="$mismatched_glue" \
ABI_EXPECT_MISMATCH=1 \
OPT=speed \
ROC_BIN="${ROC_BIN:-roc}" \
"$script_dir/run.sh"
