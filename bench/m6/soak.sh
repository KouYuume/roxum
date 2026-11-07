#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"

duration=${M6_SOAK_DURATION:-8h}
qps=${M6_SOAK_QPS:-100}
oha_bin=${OHA_BIN:-oha}
output=${M6_SOAK_OUTPUT:-reports/M6-soak.json}
progress_output=${M6_SOAK_PROGRESS_OUTPUT:-reports/M6-soak-progress.jsonl}
executable=$(mktemp "${TMPDIR:-/tmp}/roxum-m6-soak.XXXXXX")
trap 'unlink "$executable" 2>/dev/null || true' EXIT

bash bench/m6/build.sh "$executable"
python3 bench/m6/run.py \
    "$executable" \
    --oha "$oha_bin" \
    --duration "$duration" \
    --concurrency 64 \
    --qps "$qps" \
    --repeats 1 \
    --sample-interval 60 \
    --architectures processes \
    --progress-output "$progress_output" \
    --output "$output"
python3 bench/m6/soak_check.py "$output"
