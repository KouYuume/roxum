#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

roc check platform/Random.roc
roc check platform/File.roc
roc check platform/Secret.roc
roc check platform/Config.roc
