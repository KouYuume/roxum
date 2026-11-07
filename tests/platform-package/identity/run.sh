#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$repo_root"

roc_bin=${ROC_BIN:-roc}
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roxum-m9p2.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT

diff -r \
	tests/platform-package/identity/platform-a \
	tests/platform-package/identity/platform-b

"$roc_bin" check --no-cache \
	tests/platform-package/identity/positive.roc

set +e
"$roc_bin" check --no-cache \
	tests/platform-package/identity/mismatched-root.roc \
	>"$task_tmp/mismatch.log" 2>&1
status=$?
set -e

if [[ $status -eq 0 ]]; then
	echo "expected mismatched platform roots to fail" >&2
	exit 1
fi
if ! grep -qi "platform dependency mismatch" "$task_tmp/mismatch.log"; then
	cat "$task_tmp/mismatch.log" >&2
	echo "missing platform dependency mismatch diagnostic" >&2
	exit 1
fi

echo "M9P-2 exact platform identity: PASS"
