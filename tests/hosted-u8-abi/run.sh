#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

: "${ROC_BIN:=roc}"

mkdir -p platform/targets/arm64mac
clang \
    -target arm64-apple-macos \
    -O2 \
    -c host.c \
    -o platform/targets/arm64mac/host.o
ar rcs \
    platform/targets/arm64mac/libhost.a \
    platform/targets/arm64mac/host.o

for opt in speed dev interpreter; do
    "$ROC_BIN" build \
        --no-cache \
        --opt="$opt" \
        --target=arm64mac \
        --output="app-$opt" \
        app.roc

    set +e
    output="$("./app-$opt" 2>&1)"
    status=$?
    set -e

    printf '%s\n' "$opt: exit $status"
    printf '%s\n' "$output"

    if [[ $status -ne 0 ]]; then
        exit 1
    fi
done
