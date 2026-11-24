#!/usr/bin/env bash
# Build the upstream default static libraries for the same three release hosts.
set -euo pipefail
if [[ $# != 3 ]]; then
    echo "usage: $0 MBEDTLS_SOURCE_TARBALL PLATFORM_BUNDLE NEW_WORK_DIRECTORY" >&2
    exit 2
fi
source_archive=$(realpath "$1")
platform_bundle=$(realpath "$2")
probe_dir=$(cd "$(dirname "$0")" && pwd)
mkdir "$3"
cd "$3"
digest=392215e5e4846df04e2f4c4516079303bd73edde837d8f3e68fb4d4d7ddf0126
echo "$digest  $source_archive" | shasum -a 256 -c -
mkdir platform extracted
tar xf "$platform_bundle" -C platform
tar xf "$source_archive"
src="$PWD/mbedtls-4.1.2"
thread_flags="-DMBEDTLS_THREADING_C -DMBEDTLS_THREADING_PTHREAD"
for target in arm64mac arm64musl x64musl; do
    case "$target" in
        arm64mac) triple=aarch64-macos; os=Darwin; cpu=arm64 ;;
        arm64musl) triple=aarch64-linux-musl; os=Linux; cpu=aarch64 ;;
        x64musl) triple=x86_64-linux-musl; os=Linux; cpu=x86_64 ;;
    esac
    mkdir "$target"
    (
        cd "$target"
        printf '#!/bin/sh\nexec zig cc -target %s "$@"\n' "$triple" > cc
        printf '#!/bin/sh\nexec zig ar "$@"\n' > ar
        printf '#!/bin/sh\nexec zig ranlib "$@"\n' > ranlib
        chmod +x cc ar ranlib
        cmake -S "$src" -B build -G Ninja \
            -DCMAKE_SYSTEM_NAME="$os" -DCMAKE_SYSTEM_PROCESSOR="$cpu" \
            -DCMAKE_C_COMPILER="$PWD/cc" -DCMAKE_AR="$PWD/ar" -DCMAKE_RANLIB="$PWD/ranlib" \
            -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_C_FLAGS="$thread_flags -g0" \
            -DCMAKE_ARCHIVE_OUTPUT_DIRECTORY="$PWD/libs" -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF
        cmake --build build --target mbedtls --parallel "${JOBS:-4}"
        cp "../platform/targets/$target/libhost.a" base.a
        printf 'create merged.a\naddlib base.a\naddlib libs/libmbedtls.a\naddlib libs/libmbedx509.a\naddlib libs/libtfpsacrypto.a\nsave\nend\n' | zig ar -M
        wc -c base.a merged.a
        mv merged.a "../platform/targets/$target/libhost.a"
        ./cc -Wall -Wextra -Werror -Os -g0 $thread_flags -I"$src/include" -I"$src/tf-psa-crypto/include" \
            -I"$src/tf-psa-crypto/drivers/builtin/include" -I"$PWD/build/tf-psa-crypto/include" \
            -c "$probe_dir/mbedtls-server.c" -o server.o
    )
done
cp "$src/LICENSE" platform/MBEDTLS-LICENSE
cp "$src/tf-psa-crypto/LICENSE" platform/TF-PSA-CRYPTO-LICENSE
bash "$probe_dir/bundle-probes.sh" MBEDTLS-LICENSE TF-PSA-CRYPTO-LICENSE
