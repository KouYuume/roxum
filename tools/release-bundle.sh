#!/usr/bin/env bash
# Bundles the release staging copy of the platform (zig build release builds
# its stripped hosts first) into zig-out/release/<hash>.tar.zst, and checks
# that it stays within the size budget below; then each integration
# (tools/release-integrations.py), naming the platform's bundle under the
# release URL, the first argument (zig build release -Drelease-url=...).
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
: "${ROC_BIN:=roc}"

staging=zig-out/release/platform
output_dir=zig-out/release
# Bound expanded bundle size so host growth cannot silently increase download costs.
limit_bytes=$((13 * 1000 * 1000))

# The platform's Roc modules; the host sources are not part of the bundle.
rm -f "$staging"/*.roc
cp platform/*.roc "$staging/"
cp platform/NGHTTP2-LICENSE "$staging/NGHTTP2-LICENSE"

# roc bundle stores only files under the entry file's directory, so the
# platform's local packages are copied in and the header is pointed at them.
packages_dir="$staging/packages/roc-toml"
mkdir -p "$packages_dir"
rm -f "$packages_dir"/*.roc
cp libraries/roc-toml/package/*.roc "$packages_dir/"
sed 's#toml: "../libraries/roc-toml/package/main.roc"#toml: "packages/roc-toml/main.roc"#' platform/main.roc > "$staging/main.roc"
if ! grep -q 'toml: "packages/roc-toml/main.roc"' "$staging/main.roc"; then
    echo "the toml package path in platform/main.roc changed; update tools/release-bundle.sh" >&2
    exit 1
fi

target_files=()
for target_dir in "$staging"/targets/*/; do
    for file in libhost.a crt1.o libc.a; do
        if [[ -f "$target_dir$file" ]]; then
            target_files+=("${target_dir#"$staging/"}$file")
        fi
    done
done

# Also keeps "${target_files[@]}" from failing under `set -u` in bash 3.2,
# which treats an empty array as unbound.
if [[ ${#target_files[@]} -eq 0 ]]; then
    echo "no host archives under $staging/targets; build the hosts first" >&2
    exit 1
fi

release_url=${1:-}
if [[ -z "$release_url" ]]; then
    release_url="https://example.invalid/roxum/releases/download/unpublished"
    echo "no -Drelease-url: the integrations' bundles name $release_url and are not for publishing" >&2
fi

rm -f "$output_dir"/*.tar.zst "$output_dir"/release.json "$output_dir"/release-notes.md
# roc bundle stores paths relative to the entry file's directory.
(cd "$staging" && "$ROC_BIN" bundle main.roc NGHTTP2-LICENSE "${target_files[@]}" --output-dir ../) | tee "$output_dir/bundle.log"

uncompressed=$(sed -n 's/^Uncompressed size: \([0-9]*\) bytes$/\1/p' "$output_dir/bundle.log")
if [[ -z "$uncompressed" || "$uncompressed" -gt "$limit_bytes" ]]; then
    echo "bundle is ${uncompressed:-?} bytes uncompressed, over the budget of $limit_bytes in tools/release-bundle.sh" >&2
    exit 1
fi

python3 tools/release-integrations.py "$release_url"
