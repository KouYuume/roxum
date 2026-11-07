#!/usr/bin/env bash
#   ./run.sh --opt=dev
#   ./run.sh --opt=interpreter
set -euo pipefail

# Per-run scratch directory, so parallel runs do not overwrite each other.
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/mb3.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

cd "$(dirname "$0")"
: "${ROC_SRC:=$HOME/dev/roc/roc}"
SRC=.

build_host() {
  mkdir -p platform/targets/arm64mac
  roc glue "$ROC_SRC/src/glue/src/ZigGlue.roc" ./generated ./platform/main.roc >/dev/null
  zig build-obj -target aarch64-macos -fcompiler-rt -lc -O ReleaseFast --dep roc_platform_abi -Mroot="$SRC/host.zig" -Mroc_platform_abi=generated/roc_platform_abi.zig -femit-bin=$work_dir/mb3-host.o
  zig ar rcs platform/targets/arm64mac/libhost.a $work_dir/mb3-host.o
}

run_opt() {
  local opt="$1"
  echo "═══ --opt=$opt ═══"
  roc build --opt="$opt" --target=arm64mac --output="$work_dir/mb3-$opt" app.roc >/dev/null
  "$work_dir/mb3-$opt"
  echo
}

build_host

if [ "${1:-}" = "--all" ]; then
  for opt in speed dev interpreter; do
    run_opt "$opt"
  done
  exit 0
fi

OPT=speed
for arg in "$@"; do
  case "$arg" in
    --opt=*) OPT="${arg#--opt=}" ;;
  esac
done
run_opt "$OPT"
