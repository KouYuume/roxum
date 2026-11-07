#!/usr/bin/env bash
set -euo pipefail

# Per-run scratch directory, so parallel runs do not overwrite each other.
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/mb2.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

cd "$(dirname "$0")"
SRC=.
BIN=$work_dir/mb2-spike

zig build-exe -target aarch64-macos -lc -O ReleaseSafe --dep alloc -Mroot="$SRC/main.zig" -Malloc="$SRC/alloc.zig" -femit-bin="$BIN" >/dev/null

if [ "${1:-}" = "--all" ]; then
  for m in arena tracking; do
    printf "\n### mode=%s\n" "$m"
    if MB2_MODE=$m "$BIN" >/dev/null 2>&1; then
      echo "  normal       : PASS"
    else
      echo "  normal       : FAIL"
    fi
    for i in uaf leak double-free domain-mix; do
      raw=$(MB2_MODE=$m MB2_INJECT=$i "$BIN" 2>&1 || true)
      out=$(printf '%s\n' "$raw" | grep -E "injected|domain-mix:" | tail -1 | sed 's/^ *//' || true)
      printf "  %-13s: %s\n" "$i" "${out:-(no output)}"
    done
  done
  exit 0
fi

MODE=arena
INJECT=""
for arg in "$@"; do
  case "$arg" in
    --mode=*) MODE="${arg#--mode=}" ;;
    --inject=*) INJECT="${arg#--inject=}" ;;
    --inject-uaf) INJECT=uaf ;;
  esac
done

if [ -n "$INJECT" ]; then
  MB2_MODE="$MODE" MB2_INJECT="$INJECT" "$BIN"
else
  MB2_MODE="$MODE" "$BIN"
fi
