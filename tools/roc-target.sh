#!/usr/bin/env bash
# Prints the Roc target name of this machine (arm64mac, arm64musl, x64musl).
# With --zig, prints the Zig target of a Roc target instead:
#   tools/roc-target.sh --zig [roc-target]
set -euo pipefail

native_target() {
    case "$(uname -s)-$(uname -m)" in
        # Only Apple silicon is supported; a shell under Rosetta reports x86_64.
        Darwin-*) echo arm64mac ;;
        Linux-aarch64 | Linux-arm64) echo arm64musl ;;
        Linux-x86_64) echo x64musl ;;
        *)
            echo "unsupported machine: $(uname -s) $(uname -m)" >&2
            exit 1
            ;;
    esac
}

zig_target() {
    case "$1" in
        arm64mac) echo aarch64-macos ;;
        arm64musl) echo aarch64-linux-musl ;;
        x64musl) echo x86_64-linux-musl ;;
        *)
            echo "unsupported Roc target: $1" >&2
            exit 1
            ;;
    esac
}

if [[ "${1:-}" == "--zig" ]]; then
    zig_target "${2:-$(native_target)}"
else
    native_target
fi
