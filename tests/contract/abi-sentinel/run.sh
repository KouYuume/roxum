#!/usr/bin/env bash
set -euo pipefail

# Per-run scratch directory, so parallel runs do not overwrite each other.
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/roxum-abi-sentinel.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../../.." && pwd)"
: "${ROC_BIN:=roc}"
: "${OPT:=speed}"
: "${ABI_GLUE:=$script_dir/generated/roc_platform_abi.zig}"
: "${ABI_EXPECT_MISMATCH:=0}"

case "$OPT" in
    speed|dev|interpreter|all) ;;
    *)
        echo "OPT must be speed, dev, interpreter, or all" >&2
        exit 2
        ;;
esac

cd "$script_dir"
roc_target="$("$repo_root/tools/roc-target.sh")"
target_dir="platform/targets/$roc_target"
mkdir -p "$target_dir"
# Never empty: bash 3.2 treats an empty array as unset under `set -u`.
target_flags=(-fcompiler-rt -lc)
if [[ "$roc_target" == *musl ]]; then
    target_flags+=(-fPIC)
fi
# As in build.zig's host build: Zig 0.16 crashes (SIGSEGV) building any object
# for x86_64-linux-musl with -fcompiler-rt -lc in ReleaseSafe unless the stack
# protector is off.
if [[ "$roc_target" == x64musl ]]; then
    target_flags+=(-fno-stack-protector)
fi

zig build-obj \
    -target "$("$repo_root/tools/roc-target.sh" --zig "$roc_target")" \
    "${target_flags[@]}" \
    -O ReleaseSafe \
    --dep roc_platform_abi \
    -Mroot=host.zig \
    -Mroc_platform_abi="$ABI_GLUE" \
    -femit-bin=$work_dir/roxum-abi-sentinel-host.o
zig ar rcs \
    "$target_dir/libhost.a" \
    $work_dir/roxum-abi-sentinel-host.o
"$repo_root/tools/musl-runtime.sh" "$roc_target" "$target_dir"

run_one() {
    local opt="$1"
    local output="$work_dir/roxum-abi-sentinel-$opt"
    "$ROC_BIN" build \
        --no-cache \
        --opt="$opt" \
        --target="$roc_target" \
        --output="$output" \
        app.roc >/dev/null
    if [[ "$ABI_EXPECT_MISMATCH" == 1 ]]; then
        local failure_output
        local failure_status
        set +e
        failure_output="$("$output" 2>&1)"
        failure_status=$?
        set -e
        if [[ $failure_status -eq 0 ]]; then
            echo "ABI sentinel accepted an intentionally mismatched tag layout" >&2
            exit 1
        fi
        if [[ "$failure_output" != *"ABI sentinel assertion failed"* ]]; then
            echo "$failure_output" >&2
            echo "ABI mismatch failed without the sentinel diagnostic" >&2
            exit 1
        fi
        printf 'PASS — semantic ABI sentinel rejected a mismatched tag layout (%s)\n' "$opt"
        return
    fi

    "$output"
    printf 'PASS — semantic ABI sentinel (%s)\n' "$opt"
}

if [[ "$OPT" == all ]]; then
    for opt in speed dev interpreter; do
        run_one "$opt"
    done
    "$script_dir/reject-tag-mismatch.sh"
else
    run_one "$OPT"
fi
