#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

run_negative() {
    local fixture="$1"
    local expected="$2"
    local output

    set +e
    output="$(python3 "$script_dir/check-timeout.py" roc check "$script_dir/negative/$fixture" 2>&1)"
    status=$?
    set -e
    if [[ $status -eq 0 ]]; then
        echo "negative Router fixture unexpectedly succeeded: $fixture" >&2
        exit 1
    fi
    if [[ $status -eq 124 ]]; then
        echo "$output" >&2
        echo "negative Router fixture exceeded 30 seconds: $fixture" >&2
        exit 1
    fi
    if [[ "$output" != *"compile-time crash"* && "$output" != *"compile time crash"* ]]; then
        echo "$output" >&2
        echo "negative Router fixture did not report a compile-time crash: $fixture" >&2
        exit 1
    fi
    if [[ "$output" != *"$expected"* ]]; then
        echo "$output" >&2
        echo "negative Router fixture missed diagnostic '$expected': $fixture" >&2
        exit 1
    fi
}

run_negative invalid-pattern.roc "invalid route pattern"
run_negative catchall-nonterminal.roc "catch-all must be the final segment"
run_negative duplicate-parameter.roc "duplicate path parameter"
run_negative duplicate-route.roc "duplicate method and structural route"
run_negative fallback-conflict.roc "two custom fallbacks answer for the same paths"
run_negative merged-fallback.roc "the right router in a merge cannot have its own fallback"
run_negative nested-before-routing.roc "a nested router cannot have before_routing checks"
run_negative merged-before-routing.roc "the right router in a merge cannot have before_routing checks"
