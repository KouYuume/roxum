#!/usr/bin/env bash
# Called in the trial directory after its three archives and probe objects exist.
set -euo pipefail
probe_dir=$(cd "$(dirname "$0")" && pwd)
targets=(arm64mac arm64musl x64musl)
(
    cd platform
    roc bundle main.roc NGHTTP2-LICENSE "$@" targets/*/libhost.a \
        targets/*/libc.a targets/*/rcrt1.o --output-dir ..
)
tar xf ./*.tar.zst -C extracted
sed 's@../../platform/main.roc@extracted/main.roc@' "$probe_dir/../../examples/hello/app.roc" > hello.roc
for target in "${targets[@]}"; do
    case "$target" in
        arm64mac) link_flags=(-target aarch64-macos) ;;
        arm64musl) link_flags=(-target aarch64-linux-musl -static) ;;
        x64musl) link_flags=(-target x86_64-linux-musl -static) ;;
    esac
    roc build --opt=dev --target="$target" --output="$target/hello" hello.roc
    # The C probe provides its own main. Omit the Roc entry object from a
    # private link copy; hello above uses the complete extracted archive.
    cp "extracted/targets/$target/libhost.a" "$target/probe.a"
    zig ar d "$target/probe.a" host.o
    zig cc "${link_flags[@]}" "$target/server.o" "$target/probe.a" -o "$target/server"
done
