#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
: "${ROC_SRC:=$HOME/dev/roc/roc}"
: "${ROC_BIN:=roc}"

usage() {
    echo "usage: tools/regen-glue.sh [--check]" >&2
}

check_only=false
if [[ $# -gt 1 ]]; then
    usage
    exit 2
fi
if [[ $# -eq 1 ]]; then
    if [[ "$1" != "--check" ]]; then
        usage
        exit 2
    fi
    check_only=true
fi

if [[ ! -f "$ROC_SRC/src/glue/src/ZigGlue.roc" ]]; then
    echo "ROC_SRC does not point to a Roc source checkout: $ROC_SRC" >&2
    exit 1
fi

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/roxum-glue.XXXXXX")"
trap 'rm -rf -- "$temporary_dir"' EXIT

generate_one() {
    local name="$1"
    local platform_file="$2"
    local generated_file="$3"
    local output_dir="$temporary_dir/$name"
    local temporary_file="$output_dir/roc_platform_abi.zig"

    mkdir -p "$output_dir"
    "$ROC_BIN" glue \
        "$ROC_SRC/src/glue/src/ZigGlue.roc" \
        "$output_dir" \
        "$platform_file"

    if [[ ! -s "$temporary_file" ]]; then
        echo "roc glue did not generate roc_platform_abi.zig for $platform_file" >&2
        exit 1
    fi

    if [[ "$check_only" == true ]]; then
        if [[ ! -f "$generated_file" ]]; then
            echo "committed glue is missing: $generated_file" >&2
            exit 1
        fi
        diff -u -- "$generated_file" "$temporary_file"
    else
        mkdir -p "$(dirname -- "$generated_file")"
        install -m 0644 "$temporary_file" "$generated_file"
    fi
}

generate_one \
    platform \
    "$repo_root/platform/main.roc" \
    "$repo_root/platform/host/roc_platform_abi.zig"
generate_one \
    mb1 \
    "$repo_root/tests/contract/mb1/platform/main.roc" \
    "$repo_root/tests/contract/mb1/generated/roc_platform_abi.zig"
generate_one \
    mb3 \
    "$repo_root/tests/contract/mb3/platform/main.roc" \
    "$repo_root/tests/contract/mb3/generated/roc_platform_abi.zig"
generate_one \
    abi-sentinel \
    "$repo_root/tests/contract/abi-sentinel/platform/main.roc" \
    "$repo_root/tests/contract/abi-sentinel/generated/roc_platform_abi.zig"
