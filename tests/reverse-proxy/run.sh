#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$repo_root"

roc_bin=${ROC_BIN:-roc}
roc_target=$(tools/roc-target.sh)
caddy_bin=${CADDY_BIN:-caddy}
if ! command -v "$caddy_bin" >/dev/null 2>&1; then
	echo "caddy is required for the reverse proxy check" >&2
	exit 1
fi
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roxum-reverse-proxy.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT

zig build host
"$roc_bin" build --opt=speed --target="$roc_target" --output="$task_tmp/app" \
	integrations/roxum-proxy-headers/example/app.roc
python3 tests/reverse-proxy/verify.py "$task_tmp/app" "$caddy_bin" "$task_tmp"
echo "M11 behind Caddy: PASS"
