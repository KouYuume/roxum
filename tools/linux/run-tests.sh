#!/usr/bin/env bash
# The Linux test suite: the release checks (tools/release-check.sh). Runs
# natively on Linux (CI) and inside the container that tools/linux/test.sh
# starts.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
exec "$repo_root/tools/release-check.sh"
