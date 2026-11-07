#!/usr/bin/env bash
# Overloads one worker past each admission limit (a full queue, the queue
# timeout, and the requests in progress) in every backend and allocator mode.
# tools/check.py defines its apps, backends, allocators, and verify command,
# and builds and runs them; this script only runs that one test.
set -euo pipefail

exec python3 "$(cd "$(dirname "$0")/../.." && pwd)/tools/check.py" --only test-admission
