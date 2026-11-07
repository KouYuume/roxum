#!/usr/bin/env bash
# M9P-1's checks before its builds (tools/check.py): the platform package
# rejects an effect in a pure function and a private module.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"

roc_bin=${ROC_BIN:-roc}
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roxum-checks.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT

expect_check_failure() {
	fixture=$1
	expected=$2
	output=$3
	if "$roc_bin" check "$fixture" >"$output" 2>&1; then
		echo "expected roc check to fail: $fixture" >&2
		exit 1
	fi
	if ! grep -qi "$expected" "$output"; then
		cat "$output" >&2
		echo "missing diagnostic '$expected': $fixture" >&2
		exit 1
	fi
}

expect_check_failure \
	tests/platform-package/negative/purity/main.roc \
	"pure function is expected" \
	"$task_tmp/purity.log"
expect_check_failure \
	tests/platform-package/negative/private-api/main.roc \
	"package module is private" \
	"$task_tmp/private-api.log"
