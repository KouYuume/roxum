#!/usr/bin/env bash
# Stops the server while requests, a stream, and a handler that never
# returns are running, in every backend and allocator mode.
# tools/check.py defines its apps, backends, allocators, and verify command,
# and builds and runs them; this script only runs that one test.
set -euo pipefail

exec python3 "$(cd "$(dirname "$0")/../.." && pwd)/tools/check.py" --only test-graceful-shutdown
