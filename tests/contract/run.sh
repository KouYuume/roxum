#!/usr/bin/env bash
# M-1 execution-model contract suite (MB-1〜MB-4)
set -euo pipefail

cd "$(dirname "$0")/../.."

run() {
  local name="$1"
  shift
  printf '\n═══ %s ═══\n' "$name"
  "$@"
}

run "MB-1 small Model ownership (1,000,000 calls)" \
  bash tests/contract/mb1/run.sh 1000000 small
run "MB-1 large Model ownership (1,000,000 calls)" \
  bash tests/contract/mb1/run.sh 1000000 large

run "MB-2 arena normal path" \
  bash tests/contract/mb2/run.sh --mode=arena
run "MB-2 tracking normal path" \
  bash tests/contract/mb2/run.sh --mode=tracking
for injection in uaf leak double-free domain-mix; do
  run "MB-2 tracking detects $injection" \
    bash tests/contract/mb2/run.sh --mode=tracking --inject="$injection"
done

run "MB-3 request context (speed/dev/interpreter)" \
  bash tests/contract/mb3/run.sh --all

run "MB-4 direct-accept crash boundary" \
  bash tests/contract/mb4/run.sh --mode=direct
run "MB-4 supervisor fd-handoff comparison" \
  bash tests/contract/mb4/run.sh --mode=supervisor

printf '\nPASS — all M-1 execution-model contracts hold\n'
