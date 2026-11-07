#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$repo_root"

python3 tools/check-integration-manifest.py
python3 tools/check-integration-coverage.py
python3 tests/platform-package/manifest/check_failures.py
python3 tools/release_version.py --check
python3 tests/release/test_release_version.py
