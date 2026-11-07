#!/usr/bin/env bash
# One variant of the outbound TCP and TLS test (tools/check.py): makes a test
# CA and a localhost certificate in the variant's directory, then verifies
# the executable against them.
#   tests/tcp/variant.sh <executable> <variant directory>
set -euo pipefail

executable=$1
certificates="$2/certificates"
mkdir -p "$certificates"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=roxum test CA" \
	-keyout "$certificates/ca.key" -out "$certificates/ca.pem" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=localhost" \
	-keyout "$certificates/server.key" -out "$certificates/server.csr" 2>/dev/null
printf 'subjectAltName=DNS:localhost\n' > "$certificates/server.ext"
openssl x509 -req -in "$certificates/server.csr" -CA "$certificates/ca.pem" -CAkey "$certificates/ca.key" \
	-CAcreateserial -days 1 -extfile "$certificates/server.ext" -out "$certificates/server.pem" 2>/dev/null
exec python3 tests/tcp/verify.py "$executable" "$certificates"
