#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

MODE=
for arg in "$@"; do
  case "$arg" in
    --mode=direct|--mode=supervisor) MODE="${arg#--mode=}" ;;
    *) echo "usage: $0 --mode=direct|--mode=supervisor" >&2; exit 2 ;;
  esac
done
if [ -z "$MODE" ]; then
  echo "usage: $0 --mode=direct|--mode=supervisor" >&2
  exit 2
fi

TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/roxum-mb4.XXXXXX")
SERVER_PID=
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -r "$TASK_TMP"
}
trap cleanup EXIT INT TERM

cc -std=c11 -D_DARWIN_C_SOURCE -Wall -Wextra -Werror server.c -o "$TASK_TMP/server"

# Workers share the port through SO_REUSEPORT, so it is chosen up front
# rather than by binding port 0. A port another process holds makes the
# server exit with a bind error; try another.
LOG="$TASK_TMP/server.log"
for attempt in 1 2 3 4 5; do
  PORT=$((30000 + RANDOM % 20000))
  "$TASK_TMP/server" "$MODE" "$PORT" 2>"$LOG" &
  SERVER_PID=$!
  started=0
  for _ in $(seq 1 100); do
    if grep -q "READY mode=$MODE" "$LOG"; then started=1; break; fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
    sleep 0.05
  done
  if [ "$started" -eq 1 ]; then break; fi
  if kill -0 "$SERVER_PID" 2>/dev/null || ! grep -q "bind" "$LOG" || [ "$attempt" -eq 5 ]; then
    cat "$LOG" >&2
    exit 1
  fi
done
if ! grep -q "READY mode=$MODE" "$LOG"; then
  echo "server readiness timeout" >&2
  cat "$LOG" >&2
  exit 1
fi

set +e
CRASH_OUTPUT=$(curl --http1.1 --silent --show-error --include --max-time 5 \
  "http://127.0.0.1:$PORT/crash" 2>&1)
CRASH_EXIT=$?
set -e

if printf '%s' "$CRASH_OUTPUT" | grep -q "HTTP/1.1 500 Internal Server Error"; then
  CRASH_OBSERVATION=formatted_500
elif [ "$CRASH_EXIT" -ne 0 ]; then
  CRASH_OBSERVATION=connection_reset_or_empty_response
else
  CRASH_OBSERVATION=unexpected_response
fi

OK_OUTPUT=
for _ in $(seq 1 100); do
  set +e
  OK_OUTPUT=$(curl --http1.1 --silent --show-error --include --max-time 1 \
    "http://127.0.0.1:$PORT/ok" 2>&1)
  OK_EXIT=$?
  set -e
  if [ "$OK_EXIT" -eq 0 ] && printf '%s' "$OK_OUTPUT" | grep -q "HTTP/1.1 200 OK"; then
    break
  fi
  sleep 0.05
done

echo "MB-4 crash-boundary spike"
echo "  mode              = $MODE"
echo "  crash curl exit   = $CRASH_EXIT"
echo "  crash observation = $CRASH_OBSERVATION"

if [ "$OK_EXIT" -ne 0 ] || ! printf '%s' "$OK_OUTPUT" | grep -q "HTTP/1.1 200 OK"; then
  echo "  availability      = FAIL"
  cat "$LOG" >&2
  exit 1
fi
echo "  availability      = 200 after crash"

case "$MODE" in
  direct)
    if [ "$CRASH_OBSERVATION" != connection_reset_or_empty_response ]; then
      echo "  FAIL — direct worker unexpectedly returned a response"
      exit 1
    fi
    ;;
  supervisor)
    if [ "$CRASH_OBSERVATION" != formatted_500 ]; then
      echo "  FAIL — supervisor did not return formatted 500"
      printf '%s\n' "$CRASH_OUTPUT"
      exit 1
    fi
    ;;
esac

echo "  PASS"
