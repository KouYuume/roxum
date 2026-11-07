#!/usr/bin/env bash
# The release gate: every check a release must pass on this machine, in every
# Roc backend and allocator mode. CI runs the same checks; the Linux runner
# (tools/linux/run-tests.sh) calls this script.
#
# Needs roc and zig on PATH. The toolchain and ABI glue checks also need
# ROC_SRC (a Roc checkout at .roc-revision); without it they are skipped with
# a note. Not included (CI's macOS job runs them): the reverse proxy check
# (needs Caddy), the ownership contract suite, and the httparse differential
# (needs Rust). Standalone hosted-integer ABI checks and benchmarks run separately.
#
# tools/check.py runs them: it builds every test app once per backend and
# allocator, runs the checks in parallel, and runs the tests with timing
# thresholds one at a time at the end. Logs are in zig-out/check/logs/.
# Pass --jobs N to change how many jobs run at once (default: CPU count).
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ -z "${ROC_SRC:-}" ]]; then
    printf 'toolchain and ABI glue checks skipped: ROC_SRC is not set\n'
fi
exec python3 tools/check.py "$@"
