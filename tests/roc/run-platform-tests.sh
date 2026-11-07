#!/usr/bin/env bash
# Runs the expects of every platform module through platform/main.roc.
#
# `roc test` on a single module (for example platform/Router.roc) fails with a
# cold compiler cache when the module imports a hosted module (HostBody,
# HostInstant): the hosted functions get their values only from the hosted
# block in main.roc. With a warm cache it passes, so it must not be the test.
# Testing main.roc runs the expects of every module it imports; the count check
# catches a module whose expects main.roc does not reach. The run also covers
# the packages the platform depends on (libraries/roc-toml).
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

output="$(roc test platform/main.roc 2>&1)" || {
    echo "$output" >&2
    exit 1
}
echo "$output"

expected=0
for module in platform/*.roc libraries/roc-toml/package/*.roc; do
    count="$(grep -c '^expect' "$module" || true)"
    expected=$((expected + count))
done
if [[ "$output" != *"All ($expected) tests passed"* ]]; then
    echo "expected roc test platform/main.roc to run all $expected top-level expects in platform/*.roc and its packages" >&2
    exit 1
fi
