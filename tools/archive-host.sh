#!/usr/bin/env bash
set -euo pipefail
zig=$1
host=$(realpath "$2")
http2=$(realpath "$3")
tls=$(realpath "$4")
dest=$(dirname "$host")
work=$(mktemp -d "$dest/.archive.XXXXXX")
trap 'rm -rf "$work"' EXIT
(cd "$work"
    ln -s "$host" host.o
    ln -s "$http2" nghttp2.o
    ln -s "$tls" tls
    "$zig" ar -M <<'MRI'
create libhost.a
addmod host.o
addmod nghttp2.o
addlib tls/libmbedtls.a
addlib tls/libmbedx509.a
addlib tls/libtfpsacrypto.a
save
end
MRI
    mv libhost.a "$dest/libhost.a"
)
