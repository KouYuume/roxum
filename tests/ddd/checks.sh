#!/usr/bin/env bash
# The DDD example's checks before its builds (tools/check.py): the domain's
# tests, and an effect in the domain layer is a type error.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"

roc_bin=${ROC_BIN:-roc}
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roxum-checks.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT

"$roc_bin" test examples/ddd/app.roc

# Roc imports cannot escape the package root. Stage the real domain modules
# alongside the negative fixture without putting failing code in examples/.
mkdir -p "$task_tmp/examples/ddd"
cp -R examples/ddd/core "$task_tmp/examples/ddd/"
cp tests/ddd/negative.roc "$task_tmp/examples/ddd/"
cp -R tests/ddd/negative "$task_tmp/examples/ddd/"
ln -s "$repo_root/platform" "$task_tmp/platform"
ln -s "$repo_root/libraries" "$task_tmp/libraries"

# A domain function that calls an effect does not compile.
set +e
negative_output=$("$roc_bin" check "$task_tmp/examples/ddd/negative.roc" 2>&1)
negative_status=$?
set -e
if [[ $negative_status -eq 0 ]] ||
	[[ "$negative_output" != *"This function is effectful, but a pure function is expected"* ]] ||
	[[ "$negative_output" != *"UserWithEffect.roc"* ]]; then
	echo "$negative_output" >&2
	echo "the domain layer called an effect without a type error" >&2
	exit 1
fi
echo "M9b-5 domain effect is a type error: PASS"

# The endpoints, against a throwaway PostgreSQL (tests/support/postgres_server.py).
