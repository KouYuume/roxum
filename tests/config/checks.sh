#!/usr/bin/env bash
# The config test's check before its builds (tools/check.py): a base that does
# not fit the settings stops the build.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"

roc_bin=${ROC_BIN:-roc}
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roxum-checks.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT

if "$roc_bin" build --no-cache --opt=dev --output="$task_tmp/broken" tests/config/broken/app.roc \
	> "$task_tmp/broken.log" 2>&1; then
	echo "the broken base built" >&2
	exit 1
fi
grep -q "config/base.toml: missing key port" "$task_tmp/broken.log" || {
	cat "$task_tmp/broken.log" >&2
	exit 1
}
echo "broken base: PASS"
