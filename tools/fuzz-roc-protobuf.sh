#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
: "${ROC_BIN:=roc}"
: "${RUNS:=10000}"
case "$("$repo_root/tools/roc-target.sh")" in
    arm64mac|x64musl) ;;
    *) echo 'roc-fuzz 0.4.3 supports only arm64mac and x64musl; run the wire unit and differential tests on this target' >&2; exit 1 ;;
esac
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/roxum-protobuf-fuzz.XXXXXX")"
trap 'rm -rf -- "$temporary_dir"' EXIT

# Same pinned runner as the Roc router fuzz target.
url="https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst"
curl -fsSL "$url" -o "$temporary_dir/runner.tar.zst"
if command -v sha256sum >/dev/null; then
    actual="$(sha256sum "$temporary_dir/runner.tar.zst" | awk '{print $1}')"
else
    actual="$(shasum -a 256 "$temporary_dir/runner.tar.zst" | awk '{print $1}')"
fi
if [[ "$actual" != d9bae1e93e6e94f3fafb4040861402dbab90af247023461d8e5451db4a3ae0f2 ]]; then
    echo 'roc-fuzz 0.4.3 checksum mismatch' >&2
    exit 1
fi
cp "$repo_root/fuzz/roc-protobuf/target.roc" "$temporary_dir/target.roc"
cp "$repo_root/libraries/roc-protobuf/package/ProtobufWire.roc" "$temporary_dir/ProtobufWire.roc"
mkdir "$temporary_dir/corpus"
cp "$repo_root"/fuzz/corpus/roc-protobuf/* "$temporary_dir/corpus/"
"$ROC_BIN" build --fuzz --output="$temporary_dir/protobuf-fuzz" "$temporary_dir/target.roc"
"$temporary_dir/protobuf-fuzz" run "$temporary_dir/corpus" \
    --runs="$RUNS" --seed=424242 --max-input-size=4096 --timeout=5 --memory-limit=256
