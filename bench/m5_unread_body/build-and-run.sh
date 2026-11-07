#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/roxum-m5-4g.XXXXXX")
host_archive=platform/targets/arm64mac/libhost.a
saved_archive="$work_dir/libhost.saved.a"
had_archive=0

cleanup() {
    if [[ $had_archive == 1 ]]; then
        cp "$saved_archive" "$host_archive"
    else
        rm -f "$host_archive"
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT

if [[ -f $host_archive ]]; then
    cp "$host_archive" "$saved_archive"
    had_archive=1
fi

zig build-obj \
    -target aarch64-macos \
    -O ReleaseFast \
    --dep host \
    -Mroot=bench/m5_unread_body/host.zig \
    -Mhost=platform/host/host.zig \
    -femit-bin="$work_dir/host.o"
zig ar rcs "$host_archive" "$work_dir/host.o"
roc build \
    --opt=speed \
    --target=arm64mac \
    --output="$work_dir/roxum-unread-bench" \
    tests/e2e/app.roc

python3 bench/m5_unread_body/run.py \
    "$work_dir/roxum-unread-bench" \
    "$@"
