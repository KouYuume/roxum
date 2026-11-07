#!/usr/bin/env bash
# Installs the Roc nightly named in tools/linux/Dockerfile into <directory>
# and checks its SHA-256 there. CI uses this rather than building Roc from
# source: the pinned Roc needs a newer Zig to build than roxum's host uses.
#   tools/install-roc-nightly.sh <directory>
set -euo pipefail

destination=${1:?usage: tools/install-roc-nightly.sh <directory>}
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="$repo_root/tools/linux/Dockerfile"
argument() { sed -n "s/^ARG $1=//p" "$dockerfile"; }

nightly=$(argument ROC_NIGHTLY)
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) asset=linux_x86_64; sha256=$(argument ROC_SHA256_X86_64) ;;
    Linux-aarch64) asset=linux_arm64; sha256=$(argument ROC_SHA256_ARM64) ;;
    Darwin-arm64) asset=macos_apple_silicon; sha256=$(argument ROC_SHA256_MACOS_ARM64) ;;
    *) echo "no Roc nightly for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac
case "$nightly" in
    nightly-*-"$(cut -c1-7 "$repo_root/.roc-revision")") ;;
    *) echo "tools/linux/Dockerfile names $nightly, not .roc-revision" >&2; exit 1 ;;
esac

archive=$(mktemp)
trap 'rm -f "$archive"' EXIT
curl -fsSLo "$archive" \
    "https://github.com/roc-lang/nightlies/releases/download/$nightly/roc_nightly-$asset-${nightly#nightly-}.tar.gz"
if command -v sha256sum >/dev/null; then
    echo "$sha256  $archive" | sha256sum -c - >/dev/null
else
    echo "$sha256  $archive" | shasum -a 256 -c - >/dev/null
fi
mkdir -p "$destination"
tar -xz -C "$destination" --strip-components=1 -f "$archive"
"$destination/roc" version
