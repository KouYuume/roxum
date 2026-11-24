# Inbound TLS packaging trials

Mbed TLS 4.1.2 is the smaller candidate for the next intact-host handshake
trial. Shipping its complete static libraries adds 4,096,316 expanded bytes
across three targets. Both candidates exceed the current
[13,000,000-byte release limit](../../tools/release-bundle.sh).
Before adoption, measure the host configuration needed to serve TLS and use
that result to decide the distribution budget.

## Measurements

Both trials started from the same locally built 0.3.0 platform bundle, SHA-256
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
An HTTPS handshake through that application's host is the next integration check.

## Reproduce

Start on Apple silicon with the [pinned Roc and Zig](../toolchain.md), tar
with zstd support, Python and the OpenSSL CLI for generating test credentials.
Obtain the platform bundle named by a trusted `release.json` or build it with
`zig build release`. Use the corresponding upstream source release:

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
architecture. The C probe supplies its own main, so the scripts remove the Roc
entry object from a private link copy. The hello binaries use the whole
extracted archive. Start each hello binary and check that `GET /` returns
HTTP 200 and `Hello, Roc!` followed by a newline. Use `otool -L` on macOS
and `readelf -l -d` on Linux to inspect the probe's runtime dependencies.

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
all three targets. Production adoption also requires the normal host build and
release verification paths to use the pin.
