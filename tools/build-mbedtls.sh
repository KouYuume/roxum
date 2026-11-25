#!/usr/bin/env bash
set -euo pipefail
source_archive=$(realpath "$1")
export ROXUM_ZIG=$2
export ROXUM_TLS_TARGET=$3
adapter=$(realpath "$4")
out=$(realpath "$5")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
tar xf "$source_archive" --strip-components=1
python3 scripts/config.py unset-all '^MBEDTLS_(SSL_CLI_C|X509_(CREATE_C|CRT_WRITE_C|CSR_WRITE_C|CSR_PARSE_C))$'
if [[ $ROXUM_TLS_TARGET == *-linux-musl ]]; then
    cp "$adapter/tls_memory.h" tf-psa-crypto/include/roxum_tls_memory.h
    python3 scripts/config.py set TF_PSA_CRYPTO_USER_CONFIG_FILE '"roxum_tls_memory.h"'
    python3 scripts/config.py set MBEDTLS_PLATFORM_MEMORY
    python3 scripts/config.py set MBEDTLS_PLATFORM_CALLOC_MACRO roxum_tls_calloc
    python3 scripts/config.py set MBEDTLS_PLATFORM_FREE_MACRO roxum_tls_free
fi
printf '#!/bin/sh\nexec "$ROXUM_ZIG" cc -target "$ROXUM_TLS_TARGET" "$@"\n' > cc
printf '#!/bin/sh\nexec "$ROXUM_ZIG" ar "$@"\n' > ar
printf '#!/bin/sh\nexec "$ROXUM_ZIG" ranlib "$@"\n' > ranlib
chmod +x cc ar ranlib
cmake -S . -B build -G Ninja -DCMAKE_SYSTEM_NAME=Generic \
    -DCMAKE_C_COMPILER="$PWD/cc" -DCMAKE_AR="$PWD/ar" -DCMAKE_RANLIB="$PWD/ranlib" \
    -DCMAKE_BUILD_TYPE=MinSizeRel -DCMAKE_C_FLAGS="-g0 -fPIC -DMBEDTLS_THREADING_C -DMBEDTLS_THREADING_PTHREAD" \
    -DCMAKE_ARCHIVE_OUTPUT_DIRECTORY="$out" -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF
cmake --build build --target mbedtls --parallel 4
for unit in credentials session tls_memory; do
    ./cc -Os -g0 -fPIC -Wall -Wextra -Werror -DMBEDTLS_THREADING_C -DMBEDTLS_THREADING_PTHREAD \
        -Iinclude -Itf-psa-crypto/include -Itf-psa-crypto/drivers/builtin/include -Ibuild/tf-psa-crypto/include \
        -c "$adapter/$unit.c" -o "$out/$unit.o"
done
cp LICENSE "$out/MBEDTLS-LICENSE"
cp tf-psa-crypto/LICENSE "$out/TF-PSA-CRYPTO-LICENSE"
