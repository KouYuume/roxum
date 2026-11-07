#!/usr/bin/env bash
# The code in the user guides comes from tests/guide/. This builds each
# example in every backend and checks the behavior the guides describe, and
# checks that the API reference still generates.
# tools/check.py defines its apps, backends, allocators, and verify command,
# and builds and runs them; this script only runs that one test.
set -euo pipefail

exec python3 "$(cd "$(dirname "$0")/../.." && pwd)/tools/check.py" --only test-m13b
