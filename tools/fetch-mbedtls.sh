#!/usr/bin/env bash
set -euo pipefail
version=4.1.2
digest=392215e5e4846df04e2f4c4516079303bd73edde837d8f3e68fb4d4d7ddf0126
if [[ $# == 2 ]]; then
    cp "$2" "$1"
else
    curl --silent --show-error --fail --location --retry 3 --output "$1" \
        "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$version/mbedtls-$version.tar.bz2"
fi
echo "$digest  $1" | shasum -a 256 -c -
