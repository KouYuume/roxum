#!/usr/bin/env bash
# Runs the coverage-guided fuzz campaign (zig build fuzz-parser and
# fuzz-chunked with --fuzz=<runs>) and fails when any fuzz test fails.
#
# Zig 0.16's `zig build --fuzz` exits 0 even when a fuzz test panics or the
# fuzzer cannot start; it only prints the failure. This script fails on the
# build summary's failure line or a test that ended with a signal.
#   tools/fuzz.sh          # 10000 runs
#   tools/fuzz.sh 100000
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

runs="${1:-10000}"
log="$(mktemp "${TMPDIR:-/tmp}/roxum-fuzz.XXXXXX")"
trap 'rm -f "$log"' EXIT

# One fuzz test at a time: Zig 0.16's fuzzers, started together on an empty
# cache, fail to create their files there on macOS.
for step in fuzz-parser fuzz-chunked; do
    set +e
    zig build "$step" --fuzz="$runs" 2>&1 | tee "$log"
    build_status=${PIPESTATUS[0]}
    set -e

    if [[ $build_status -ne 0 ]]; then
        exit "$build_status"
    fi
    if grep -Eq -- '\+- run test failure|terminated with signal|^thread [0-9]+ panic' "$log"; then
        echo "fuzz: a fuzz test failed in $step (see the output above)" >&2
        exit 1
    fi
done
