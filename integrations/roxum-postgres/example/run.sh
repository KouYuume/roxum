#!/usr/bin/env bash
# Runs roxum-postgres against a throwaway PostgreSQL: the local binaries
# when installed, otherwise Docker's postgres:17 (tests/support/postgres_server.py).
# tools/check.py defines its apps, backends, allocators, and verify command,
# and builds and runs them; this script only runs that one test.
set -euo pipefail

exec python3 "$(cd "$(dirname "$0")/../../.." && pwd)/tools/check.py" --only test-postgres
