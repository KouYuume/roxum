#!/usr/bin/env bash
set -euo pipefail
source_archive=$(realpath "$1")
export ROXUM_ZIG=$2
export ROXUM_TLS_TARGET=$3
out=$(realpath "$4")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
tar xf "$source_archive" --strip-components=1
python3 scripts/config.py unset-all '^MBEDTLS_(SSL_CLI_C|X509_(CREATE_C|CRT_WRITE_C|CSR_WRITE_C|CSR_PARSE_C))$'
printf '#!/bin/sh\nexec "$ROXUM_ZIG" cc -target "$ROXUM_TLS_TARGET" "$@"\n' > cc
printf '#!/bin/sh\nexec "$ROXUM_ZIG" ar "$@"\n' > ar
printf '#!/bin/sh\nexec "$ROXUM_ZIG" ranlib "$@"\n' > ranlib
chmod +x cc ar ranlib
cmake -S . -B build -G Ninja -DCMAKE_SYSTEM_NAME=Generic \
    -DCMAKE_C_COMPILER="$PWD/cc" -DCMAKE_AR="$PWD/ar" -DCMAKE_RANLIB="$PWD/ranlib" \
    -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_C_FLAGS="-g0 -fPIC -DMBEDTLS_THREADING_C -DMBEDTLS_THREADING_PTHREAD" \
    -DCMAKE_ARCHIVE_OUTPUT_DIRECTORY="$out" -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF
cmake --build build --target mbedtls --parallel 4
cp LICENSE "$out/MBEDTLS-LICENSE"
cp tf-psa-crypto/LICENSE "$out/TF-PSA-CRYPTO-LICENSE"
