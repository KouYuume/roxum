#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${ROC_BIN:=roc}"
target="$1"
arena_object="$2"
tracking_object="$3"
engine_object="$4"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/roxum-http2-roc.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
# Copy current platform sources, keeping the fixture archive isolated from the
# production target directory and concurrent release-check builds.
python3 - "$work_dir" <<'PY'
import pathlib, shutil, sys
root = pathlib.Path(sys.argv[1])
shutil.copytree('platform', root / 'platform', ignore=shutil.ignore_patterns('host', 'targets'))
shutil.copytree('libraries/roc-toml', root / 'libraries/roc-toml')
(root / 'tests/http2-roc').mkdir(parents=True)
shutil.copyfile('tests/http2-roc/app.roc', root / 'tests/http2-roc/app.roc')
PY
mkdir -p "$work_dir/platform/targets/$target"
bash tools/musl-runtime.sh "$target" "$work_dir/platform/targets/$target"
venv=zig-out/http2-roc/venv
if [[ ! -x "$venv/bin/python" ]]; then python3 -m venv "$venv"; fi
"$venv/bin/python" -m pip install --disable-pip-version-check --require-hashes --only-binary=:all: -r tests/http2-engine/requirements.txt
for allocator in arena tracking; do
    object="$arena_object"
    if [[ "$allocator" == tracking ]]; then object="$tracking_object"; fi
    rm -f "$work_dir/platform/targets/$target/libhost.a"
    zig ar rcs "$work_dir/platform/targets/$target/libhost.a" "$object" "$engine_object"
    for backend in speed dev interpreter; do
        output="$work_dir/app-$allocator-$backend"
        "$ROC_BIN" build --no-cache --opt="$backend" --target="$target" --output="$output" "$work_dir/tests/http2-roc/app.roc"
        "$venv/bin/python" tests/http2-roc/verify.py "$output" "$allocator" "$backend"
    done
done
