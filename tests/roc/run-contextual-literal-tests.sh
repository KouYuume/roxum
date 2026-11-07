#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"

run_negative() {
    local fixture="$1"
    local heading="$2"
    local diagnostic="$3"
    local output
    local exit_status

    set +e
    output="$(python3 "$script_dir/check-timeout.py" roc check "$script_dir/negative/$fixture" 2>&1)"
    exit_status=$?
    set -e
    if [[ $exit_status -eq 0 ]]; then
        echo "negative contextual literal fixture unexpectedly succeeded: $fixture" >&2
        exit 1
    fi
    if [[ $exit_status -eq 124 ]]; then
        echo "$output" >&2
        echo "negative contextual literal fixture exceeded 30 seconds: $fixture" >&2
        exit 1
    fi
    if [[ "$output" != *"$heading"* ]]; then
        echo "$output" >&2
        echo "negative contextual literal fixture missed heading '$heading': $fixture" >&2
        exit 1
    fi
    if [[ "$output" != *"$diagnostic"* ]]; then
        echo "$output" >&2
        echo "negative contextual literal fixture missed diagnostic '$diagnostic': $fixture" >&2
        exit 1
    fi
}

run_negative json-reply-f64.roc "type mismatch" "encode_f64"
run_negative typed-try-reply-field.roc "missing method" "parser_for"
run_negative bad-status.roc "invalid number" "HTTP status must be in 200..599"
run_negative bad-header-value.roc "invalid string" "header value must not contain CR or LF"
run_negative unsafe-status-constructor.roc "cannot use opaque nominal type" "Status"
run_negative unsafe-header-constructor.roc "cannot use opaque nominal type" "HeaderValue"
run_negative unsafe-path-segment-constructor.roc "cannot use opaque nominal type" "PathSegment"
run_negative unsafe-query-value-constructor.roc "cannot use opaque nominal type" "QueryValue"

run_negative dot-path-segment.roc "invalid string" "path segment must not be . or .."
run_negative dot-dot-path-segment.roc "invalid string" "path segment must not be . or .."
run_negative empty-path-segment.roc "invalid string" "path segment must not be empty"
# The stream handle is not public at all since M24: stages and streaming
# handlers get the body instead, so app code cannot name or forge it.
run_negative unsafe-request-stream-constructor.roc "package module is private" "pf.RequestStream"

run_negative private-request-decoder.roc "package module is private" "pf.RequestDecoder"
