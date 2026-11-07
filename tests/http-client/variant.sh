#!/usr/bin/env bash
# One variant of the outbound HTTP client test (tools/check.py): makes a test
# CA and EC and RSA localhost certificates in the variant's directory, then
# verifies the executable against them.
#   tests/http-client/variant.sh <executable> <variant directory>
set -euo pipefail

executable=$1
certificates="$2/certificates"
mkdir -p "$certificates"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=roxum test CA" \
	-keyout "$certificates/ca.key" -out "$certificates/ca.pem" 2>/dev/null
printf 'subjectAltName=DNS:localhost\n' > "$certificates/server.ext"
for kind in ec rsa; do
	if [[ "$kind" == ec ]]; then
		key_options=(-newkey ec -pkeyopt ec_paramgen_curve:P-256)
	else
		key_options=(-newkey rsa:2048)
	fi
	openssl req "${key_options[@]}" -nodes -subj "/CN=localhost" \
		-keyout "$certificates/server-$kind.key" -out "$certificates/server-$kind.csr" 2>/dev/null
	openssl x509 -req -in "$certificates/server-$kind.csr" -CA "$certificates/ca.pem" -CAkey "$certificates/ca.key" \
		-CAcreateserial -days 1 -extfile "$certificates/server.ext" -out "$certificates/server-$kind.pem" 2>/dev/null
done
exec python3 tests/http-client/verify.py "$executable" "$certificates"
