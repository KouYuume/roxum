#!/usr/bin/env bash
# Build a static Mbed TLS trial for the three release targets.
set -euo pipefail
probe_dir=$(cd "$(dirname "$0")" && pwd)
host_trial=false
if [[ $# == 3 && $1 == --host-trial ]]; then
    host_trial=true
    source_archive=$(realpath "$2")
elif [[ $# == 3 ]]; then
    source_archive=$(realpath "$1")
    platform_bundle=$(realpath "$2")
else
    echo "usage: $0 MBEDTLS_SOURCE_TARBALL PLATFORM_BUNDLE NEW_WORK_DIRECTORY" >&2
    echo "       $0 --host-trial MBEDTLS_SOURCE_TARBALL NEW_WORK_DIRECTORY" >&2
    exit 2
fi
mkdir "$3"
cd "$3"
digest=392215e5e4846df04e2f4c4516079303bd73edde837d8f3e68fb4d4d7ddf0126
echo "$digest  $source_archive" | shasum -a 256 -c -
if "$host_trial"; then
    mkdir source
    git -C "$probe_dir/../.." archive HEAD | tar xf - -C source
    (cd source && patch -f -p1 < "$probe_dir/accept.patch" && zig build release)
    release="$PWD/source/zig-out/release"
    bundle_name=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["platform"]["file"])' "$release/release.json")
    platform_bundle="$release/$bundle_name"
fi
mkdir platform extracted
tar xf "$platform_bundle" -C platform
tar xf "$source_archive"
src="$PWD/mbedtls-4.1.2"
thread_flags="-DMBEDTLS_THREADING_C -DMBEDTLS_THREADING_PTHREAD"
if "$host_trial"; then
    # Only the temporary source tree changes. Keep the upstream PSA algorithms
    # and the certificate parser used by the server.
    (cd "$src" && python3 scripts/config.py unset-all \
        '^MBEDTLS_(SSL_CLI_C|X509_(CREATE_C|CRT_WRITE_C|CSR_WRITE_C|CSR_PARSE_C))$')
fi
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
        c_flags="$thread_flags -g0"
        if "$host_trial" && [[ $os == Linux ]]; then
            # Roc links the complete musl application as a static PIE.
            c_flags="$c_flags -fPIC"
        fi
        cmake -S "$src" -B build -G Ninja \
            -DCMAKE_SYSTEM_NAME="$os" -DCMAKE_SYSTEM_PROCESSOR="$cpu" \
            -DCMAKE_C_COMPILER="$PWD/cc" -DCMAKE_AR="$PWD/ar" -DCMAKE_RANLIB="$PWD/ranlib" \
            -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_C_FLAGS="$c_flags" \
            -DCMAKE_ARCHIVE_OUTPUT_DIRECTORY="$PWD/libs" -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF
        cmake --build build --target mbedtls --parallel "${JOBS:-4}"
        cp "../platform/targets/$target/libhost.a" base.a
        printf 'create merged.a\naddlib base.a\naddlib libs/libmbedtls.a\naddlib libs/libmbedx509.a\naddlib libs/libtfpsacrypto.a\nsave\nend\n' | zig ar -M
        probe_flags=(-Wall -Wextra -Werror -Os $c_flags -I"$src/include" -I"$src/tf-psa-crypto/include"
                     -I"$src/tf-psa-crypto/drivers/builtin/include" -I"$PWD/build/tf-psa-crypto/include")
        ./cc "${probe_flags[@]}" -c "$probe_dir/mbedtls-server.c" -o server.o
        if "$host_trial"; then
            ./cc "${probe_flags[@]}" -DROXUM_TRIAL_HOST -c "$probe_dir/mbedtls-server.c" -o tls-trial.o
            zig ar rcs merged.a tls-trial.o
        fi
        wc -c base.a merged.a
        mv merged.a "../platform/targets/$target/libhost.a"
    )
done
cp "$src/LICENSE" platform/MBEDTLS-LICENSE
cp "$src/tf-psa-crypto/LICENSE" platform/TF-PSA-CRYPTO-LICENSE
bash "$probe_dir/bundle-probes.sh" MBEDTLS-LICENSE TF-PSA-CRYPTO-LICENSE
