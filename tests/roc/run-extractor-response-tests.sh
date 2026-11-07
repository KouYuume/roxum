#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

roc check platform/Extract.roc
roc check platform/RequestDecoder.roc
roc check tests/e2e/app.roc
