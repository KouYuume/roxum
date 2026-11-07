#!/usr/bin/env bash
set -euo pipefail

# Per-run scratch directory, so parallel runs do not overwrite each other.
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/mb1.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

cd "$(dirname "$0")"
: "${ROC_SRC:=$HOME/dev/roc/roc}"

ITERATIONS="${1:-1000000}"
VARIANT="${2:-small}"
EXTRA="${3:-}"

APP="app-${VARIANT}.roc"
if [ ! -f "$APP" ]; then
  echo "no such app: $APP" >&2
  exit 1
fi

echo "=== 1. Generate glue (also checks that it is idempotent) ==="
mkdir -p platform/targets/arm64mac
roc glue "$ROC_SRC/src/glue/src/ZigGlue.roc" ./generated ./platform/main.roc >/dev/null

echo "=== 2. Compile the host ==="
zig build-obj -target aarch64-macos -fcompiler-rt -lc -O ReleaseFast --dep roc_platform_abi -Mroot=host.zig -Mroc_platform_abi=generated/roc_platform_abi.zig -femit-bin=$work_dir/mb1-host.o

zig ar rcs platform/targets/arm64mac/libhost.a $work_dir/mb1-host.o

echo "=== 3. Build the app (${APP}) ==="
roc build --opt=speed --target=arm64mac --output="$work_dir/mb1-${VARIANT}" "$APP"

echo "=== 4. Run ==="
export MB1_ITERATIONS="$ITERATIONS"
if [ "$EXTRA" = "--no-incref" ]; then
  export MB1_NO_INCREF=1
fi
"$work_dir/mb1-${VARIANT}"
