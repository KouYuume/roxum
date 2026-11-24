# Inbound TLS packaging trials

The standard platform bundle ships Mbed TLS 4.1.2 in the host archive for
all three targets. The [expanded release limit](../../tools/release-bundle.sh)
is 17,000,000 bytes. The host build verifies the upstream source digest,
compiles the server configuration and includes both upstream licenses in the
release. The standard bundle measured 16,483,764 bytes expanded and 5,111,692
bytes compressed on adoption. Direct TLS listener support is tracked in the [0.4 plan](inbound-tls-0.4.md).

## Measurements

The standalone trials started from the same locally built 0.3.0 platform bundle, SHA-256
`af01b5c411b94845ea9cf380a512cd0747aca73cdbdb7019ce2fd2b3124f650a`.
Each candidate includes the engine archives and upstream licenses.

| Bytes | Existing | OpenSSL 3.5.9 | Mbed TLS 4.1.2 |
|---|---:|---:|---:|
| Expanded bundle | 12,748,496 | 47,415,735 | 16,844,812 |
| Compressed bundle | 3,843,612 | 14,068,698 | 5,221,595 |
| arm64mac host archive | 2,076,944 | 12,195,184 | 3,307,320 |
| arm64musl host archive | 2,495,002 | 14,612,772 | 3,932,786 |
| x64musl host archive | 2,964,290 | 15,385,344 | 4,332,738 |

For both engines, the standalone probe passed all seven ALPN cases with a
certificate-verifying client on Apple silicon, Linux arm64 and emulated Linux
x86_64. On macOS the probe links only libSystem. Both musl probes are static.
On all three targets the hello Roc application linked against the complete
extracted host archive and served the expected cleartext HTTP/1.1 response.

## Intact-host trial

The trial builds the release host in a disposable copy of the source tree
and inserts one hook after TCP accept. With trial credentials, the worker
drives a handshake on the accepted socket and closes it. Without credentials,
the same executable serves the hello route. The app uses the complete archive
from the extracted bundle, including its normal host entry point and the TLS
engine. The trial worker loads its certificate chain and matching private key before
reporting readiness. Its TLS sessions borrow that configuration until worker
shutdown. Replacing credential files takes effect on the next worker start.
The test hook polls synchronously.
Production admission, readiness scheduling and encrypted HTTP remain separate
steps in the [0.4 plan](inbound-tls-0.4.md).

Before adopting the engine, the instrumented bundle measured **16,496,190 bytes expanded** and **5,112,110 bytes
compressed**, 3,496,190 bytes above the previous 13 MB limit. The intermediate
release build with the accept hook measured 12,748,768 bytes expanded.
On Apple silicon, Linux arm64 and emulated Linux x86_64, a verifying client
exercised all seven ALPN cases for each of TLS 1.2 and TLS 1.3. The verifier
checked the worker’s result for each connection, including the HTTP/1.1
fallback when the client omitted ALPN. The same
hello binary served its cleartext route on each target. The macOS executable
links only libSystem and both Linux executables are static PIE.

The server build disables the TLS client, X.509 certificate writing, and
certificate signing request parsing and writing. It retains the default cryptographic
algorithms. Compile the musl libraries and adapter with `-fPIC` for Roc's
static PIE linker. The standalone static probe can link without this flag.

## Reproduce

Start on Apple silicon with the [pinned Roc and Zig](../toolchain.md), tar
with zstd support, Python and the OpenSSL CLI for generating test credentials.
For the standalone comparisons, use a 0.3.0 platform bundle from a trusted
release manifest. Use the corresponding upstream source release:

| Candidate | Source asset | Additional build tools |
|---|---|---|
| OpenSSL | [openssl-3.5.9.tar.gz](https://github.com/openssl/openssl/releases/tag/openssl-3.5.9) | Perl and make |
| Mbed TLS | [mbedtls-4.1.2.tar.bz2](https://github.com/Mbed-TLS/mbedtls/releases/tag/mbedtls-4.1.2) including TF-PSA-Crypto 1.1.2 | CMake and Ninja |

Run either script with a new work directory. Each checks the source digest,
cross-builds the libraries and reports archive and bundle sizes.

```sh
bash tests/inbound-tls/package-openssl.sh openssl-3.5.9.tar.gz "$platform_bundle" "$openssl_trial"
bash tests/inbound-tls/package-mbedtls.sh mbedtls-4.1.2.tar.bz2 "$platform_bundle" "$mbedtls_trial"
```

For each trial, run `python3 tests/inbound-tls/verify.py --server "$trial/arm64mac/server"`.
Run the same verifier with the corresponding musl executable on each Linux
architecture. For the Mbed TLS probe, add `--check-write-wait` to saturate the
socket send buffer and check handshake resumption and cleanup on peer close.
The C probe supplies its own main, so the scripts remove the Roc
entry object from a private link copy. The hello binaries use the whole
extracted archive. Start each hello binary and check that `GET /` returns
HTTP 200 and `Hello, Roc!` followed by a newline. Use `otool -L` on macOS
and `readelf -l -d` on Linux to inspect the probe's runtime dependencies.

To reproduce the intact-host trial, run these commands in the checkout with
Git and patch installed. The script builds the committed host at HEAD in the
new work directory. The verifier supplies temporary credentials and checks
the cleartext route and all seven ALPN cases separately for TLS 1.2 and 1.3.

```sh
bash tests/inbound-tls/package-mbedtls.sh --host-trial mbedtls-4.1.2.tar.bz2 "$host_trial"
python3 tests/inbound-tls/verify-host.py "$host_trial/arm64mac/hello"
```

Run the same verifier with the extracted application's `arm64musl/hello` and
`x64musl/hello` binaries on their respective Linux architectures.

## Engine configurations and updates

OpenSSL uses size optimization, the built-in default provider, OS entropy
seeding and architecture-specific assembly. The trial disables loadable
modules, engines and shared libraries and includes the Apache-2.0 license.

Mbed TLS uses the upstream default algorithms, MinSizeRel, PSA's default
OS-backed entropy and pthread locking. The bundle includes the Mbed TLS and
TF-PSA-Crypto licenses. The [4.1 LTS branch](https://github.com/Mbed-TLS/mbedtls/blob/mbedtls-4.1.2/BRANCHES.md)
receives security and bug fixes through March 2029.

Update the engine version and source digest together. Check upstream security
advisories and licenses, then repeat size, linkage and handshake checks on
all three targets. Update the [host source pin](../../tools/fetch-mbedtls.sh) and the standalone
trial pin together.
