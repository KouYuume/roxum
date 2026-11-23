#!/usr/bin/env bash
# Installs the Roc release or nightly named in tools/linux/Dockerfile into
# <directory> and checks its SHA-256 there. CI uses the same prebuilt compiler.
#   tools/install-roc.sh <directory>
set -euo pipefail

destination=${1:?usage: tools/install-roc.sh <directory>}
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="$repo_root/tools/linux/Dockerfile"
argument() { sed -n "s/^ARG $1=//p" "$dockerfile"; }

release=$(argument ROC_RELEASE)
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) asset=linux_x86_64; sha256=$(argument ROC_SHA256_X86_64) ;;
    Linux-aarch64) asset=linux_arm64; sha256=$(argument ROC_SHA256_ARM64) ;;
    Darwin-arm64) asset=macos_apple_silicon; sha256=$(argument ROC_SHA256_MACOS_ARM64) ;;
    *) echo "no Roc build for $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac
# Nightly names carry the commit; a release's commit is its tag's, which the
# pin update checks (docs/toolchain.md).
case "$release" in
    nightly-*-"$(cut -c1-7 "$repo_root/.roc-revision")")
        url="https://github.com/roc-lang/nightlies/releases/download/$release/roc_nightly-$asset-${release#nightly-}.tar.gz" ;;
    nightly-*) echo "tools/linux/Dockerfile names $release, not .roc-revision" >&2; exit 1 ;;
    *) url="https://github.com/roc-lang/roc/releases/download/$release/roc-$asset-$release.tar.gz" ;;
esac

archive=$(mktemp)
trap 'rm -f "$archive"' EXIT
curl -fsSLo "$archive" "$url"
if command -v sha256sum >/dev/null; then
    echo "$sha256  $archive" | sha256sum -c - >/dev/null
else
    echo "$sha256  $archive" | shasum -a 256 -c - >/dev/null
fi
mkdir -p "$destination"
tar -xz -C "$destination" --strip-components=1 -f "$archive"
"$destination/roc" version
