#!/usr/bin/env bash
# Run with the pinned Zig and Roc on Apple silicon. The working directory
# holds the candidate bundle and probes; the input release stays untouched.
set -euo pipefail
if [[ $# != 3 ]]; then
    echo "usage: $0 OPENSSL_SOURCE_TARBALL PLATFORM_BUNDLE NEW_WORK_DIRECTORY" >&2
    exit 2
fi
source_archive=$(realpath "$1")
platform_bundle=$(realpath "$2")
probe_dir=$(cd "$(dirname "$0")" && pwd)
probe_source="$probe_dir/server.c"
mkdir "$3"
cd "$3"
work=$PWD
version=3.5.9
digest=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
echo "$digest  $source_archive" | shasum -a 256 -c -
tar xf "$source_archive"
source_dir="$work/openssl-$version"
mkdir platform extracted
tar xf "$platform_bundle" -C platform
cp "$source_dir/LICENSE.txt" platform/OPENSSL-LICENSE
targets=(arm64mac arm64musl x64musl)
for target in "${targets[@]}"; do
    case "$target" in
        arm64mac) triple=aarch64-macos; config=darwin64-arm64-cc ;;
        arm64musl) triple=aarch64-linux-musl; config=linux-aarch64 ;;
        x64musl) triple=x86_64-linux-musl; config=linux-x86_64 ;;
    esac
    mkdir "$target"
    (
        cd "$target"
        CC="zig cc -target $triple" AR="zig ar" RANLIB="zig ranlib" \
            "$source_dir/Configure" "$config" no-shared no-tests no-apps no-docs \
                no-dso no-module no-engine no-legacy no-comp -Os -g0
        make -j"${JOBS:-4}" build_libs
        cp "../platform/targets/$target/libhost.a" base.a
        printf 'create merged.a\naddlib base.a\naddlib libssl.a\naddlib libcrypto.a\nsave\nend\n' | zig ar -M
        wc -c base.a merged.a
        mv merged.a "../platform/targets/$target/libhost.a"
        zig cc -target "$triple" -Os -g0 -Iinclude -I"$source_dir/include" -c "$probe_source" -o server.o
    )
done
(
    cd platform
    roc bundle main.roc NGHTTP2-LICENSE OPENSSL-LICENSE targets/*/libhost.a \
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
