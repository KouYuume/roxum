#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
: "${ROC_BIN:=roc}"
: "${RUNS:=10000}"

temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/roxum-router-fuzz.XXXXXX")"
trap 'rm -rf -- "$temporary_dir"' EXIT

roc_fuzz_url="https://github.com/lukewilliamboswell/roc-fuzz/releases/download/0.4.3/41NK5FShyGC9Z8HNpUdUeXMWwLmLNfFxsfmLvdPL4Fxb.tar.zst"
roc_fuzz_sha256="d9bae1e93e6e94f3fafb4040861402dbab90af247023461d8e5451db4a3ae0f2"
roc_fuzz_archive="$temporary_dir/roc-fuzz-0.4.3.tar.zst"

curl -fsSL "$roc_fuzz_url" -o "$roc_fuzz_archive"
if command -v sha256sum >/dev/null; then
    actual_sha256="$(sha256sum "$roc_fuzz_archive" | awk '{print $1}')"
else
    actual_sha256="$(shasum -a 256 "$roc_fuzz_archive" | awk '{print $1}')"
fi
if [[ "$actual_sha256" != "$roc_fuzz_sha256" ]]; then
    echo "roc-fuzz 0.4.3 checksum mismatch" >&2
    exit 1
fi

cp "$repo_root/fuzz/roc-router/target.roc" "$temporary_dir/target.roc"
cp "$repo_root/platform/Handler.roc" "$temporary_dir/Handler.roc"
cp "$repo_root/platform/HeaderValue.roc" "$temporary_dir/HeaderValue.roc"
cp "$repo_root/platform/HttpError.roc" "$temporary_dir/HttpError.roc"
# fuzz/roc-router/Http.roc is a hand-reduced copy of platform/Http.roc. Stop
# if the Method variants the router matches on have drifted apart.
python3 - "$repo_root/platform/Http.roc" "$repo_root/fuzz/roc-router/Http.roc" <<'PYTHON'
import re, sys

def methods(path):
    text = open(path).read()
    match = re.search(r"Method := \[([^\]]*)\]", text)
    if not match:
        sys.exit(f"no Method union in {path}")
    return [name.strip() for name in match.group(1).replace("\n", " ").split(",") if name.strip()]

platform, fuzz = methods(sys.argv[1]), methods(sys.argv[2])
if platform != fuzz:
    sys.exit(f"fuzz/roc-router/Http.roc Method {fuzz} differs from platform/Http.roc {platform}")
PYTHON
cp "$repo_root/fuzz/roc-router/Http.roc" "$temporary_dir/Http.roc"
cp "$repo_root/platform/MethodRouter.roc" "$temporary_dir/MethodRouter.roc"
cp "$repo_root/platform/Middleware.roc" "$temporary_dir/Middleware.roc"
cp "$repo_root/platform/PathParam.roc" "$temporary_dir/PathParam.roc"
cp "$repo_root/platform/PercentEncoding.roc" "$temporary_dir/PercentEncoding.roc"
cp "$repo_root/platform/RouteContext.roc" "$temporary_dir/RouteContext.roc"
cp "$repo_root/platform/RouteError.roc" "$temporary_dir/RouteError.roc"
cp "$repo_root/platform/RouteProbe.roc" "$temporary_dir/RouteProbe.roc"
cp "$repo_root/platform/Reply.roc" "$temporary_dir/Reply.roc"
cp "$repo_root/platform/FileRoot.roc" "$temporary_dir/FileRoot.roc"
cp "$repo_root/fuzz/roc-router/ResponseWriter.roc" "$temporary_dir/ResponseWriter.roc"
cp "$repo_root/platform/Respond.roc" "$temporary_dir/Respond.roc"
cp "$repo_root/platform/Router.roc" "$temporary_dir/Router.roc"
cp "$repo_root/platform/RequestHead.roc" "$temporary_dir/RequestHead.roc"
cp "$repo_root/platform/Routes.roc" "$temporary_dir/Routes.roc"
cp "$repo_root/platform/MediaType.roc" "$temporary_dir/MediaType.roc"
cp "$repo_root/platform/ContentDisposition.roc" "$temporary_dir/ContentDisposition.roc"
cp "$repo_root/platform/JsonLines.roc" "$temporary_dir/JsonLines.roc"
cp "$repo_root/platform/Instant.roc" "$temporary_dir/Instant.roc"
cp "$repo_root/fuzz/roc-router/HostInstant.roc" "$temporary_dir/HostInstant.roc"
cp "$repo_root/fuzz/roc-router/Pipeline.roc" "$temporary_dir/Pipeline.roc"
cp "$repo_root/fuzz/roc-router/RequestDecoder.roc" "$temporary_dir/RequestDecoder.roc"
cp "$repo_root/platform/Status.roc" "$temporary_dir/Status.roc"
mkdir -p "$temporary_dir/corpus"
cp "$repo_root/fuzz/corpus/roc-router/seed" "$temporary_dir/corpus/seed"

"$ROC_BIN" build --fuzz --output="$temporary_dir/router-fuzz" "$temporary_dir/target.roc"
"$temporary_dir/router-fuzz" run "$temporary_dir/corpus" \
    --runs="$RUNS" \
    --seed=424242 \
    --max-input-size=4096 \
    --timeout=5 \
    --memory-limit=256
