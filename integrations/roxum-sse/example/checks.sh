#!/usr/bin/env bash
# roxum-sse's checks before its builds (tools/check.py): its tests, and an
# event built without the constructor is a type error.
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$repo_root"

roc_bin=${ROC_BIN:-roc}
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/roxum-checks.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT

"$roc_bin" test integrations/roxum-sse/package/main.roc
python3 - "$roc_bin" <<'PY'
import subprocess
import sys

result = subprocess.run(
    [sys.argv[1], "check", "integrations/roxum-sse/example/unsafe-event.roc"],
    capture_output=True, text=True, timeout=30,
)
output = result.stdout + result.stderr
if result.returncode == 0 or "cannot use opaque nominal type" not in output or "Sse.Event" not in output:
    raise SystemExit("SSE event constructor boundary failed:\n" + output)
print("SSE event constructor is opaque: PASS")
PY
