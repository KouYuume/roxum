#!/usr/bin/env bash
# Runs the expects of roxum-http-client's pure modules (URLs, and HTTP/1.1
# messages). They import nothing hosted, so `roc test` works on each module
# alone even with a cold cache.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

for module in integrations/roxum-http-client/package/HttpUrl.roc integrations/roxum-http-client/package/HttpWire.roc; do
    expected="$(grep -c '^expect' "$module")"
    output="$(roc test "$module" 2>&1)" || {
        echo "$output" >&2
        exit 1
    }
    echo "$output"
    if [[ "$output" != *"All ($expected) tests passed"* ]]; then
        echo "expected roc test $module to run all $expected top-level expects" >&2
        exit 1
    fi
done
