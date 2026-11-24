# Inbound TLS packaging trial

This trial measures the cost of shipping the complete static OpenSSL protocol
and crypto archives inside the existing platform bundle. It uses the 0.3
release layout and the [handshake probe](../../tests/inbound-tls/server.c).
The result applies to this build configuration. A reduced algorithm set,
link-time pruning or a different TLS engine needs its own measurement.

## Measurements

The input was a locally built 0.3.0 platform bundle with SHA-256
`af01b5c411b94845ea9cf380a512cd0747aca73cdbdb7019ce2fd2b3124f650a`.
It measured 12,748,496 bytes expanded (3,843,612 compressed). The trial bundle measured 47,415,735
bytes expanded (14,068,698 compressed). The [release limit](../../tools/release-bundle.sh)
is 13,000,000 expanded bytes. This configuration exceeds it by 34,415,735 bytes.

| Host archive | Existing bytes | With OpenSSL |
|---|---:|---:|
| arm64mac | 2,076,944 | 12,195,184 |
| arm64musl | 2,495,002 | 14,612,772 |
| x64musl | 2,964,290 | 15,385,344 |

On Apple silicon, Linux arm64 and emulated Linux x86_64, the standalone TLS
probe passed all seven ALPN cases. The macOS probe links only libSystem;
both musl probes are static. On the same targets, the hello Roc application
served its expected cleartext HTTP/1.1 response with the complete extracted
host archive.

This OpenSSL configuration exceeds the release budget. A TLS handshake
from a Roc application using the intact extracted host remains unverified
in the [engine packaging phase](inbound-tls-0.4.md#2-select-and-package-the-server-engine).

## Reproduce

Start on Apple silicon with the [pinned Roc and Zig](../toolchain.md), Perl,
make and tar with zstd support. Obtain the platform bundle named by a trusted
`release.json` (or build it with `zig build release`). Download
[openssl-3.5.9.tar.gz](https://github.com/openssl/openssl/releases/tag/openssl-3.5.9).
The [trial script](../../tests/inbound-tls/package-openssl.sh) checks the source
digest, configures OpenSSL separately for each target and keeps the trial in
a new directory. Allow several hundred megabytes of scratch space plus the
compiler cache.

```sh
bash tests/inbound-tls/package-openssl.sh openssl-3.5.9.tar.gz "$platform_bundle" "$trial_dir"
python3 tests/inbound-tls/verify.py --server "$trial_dir/arm64mac/server"
```

For each Linux architecture run the same Python verifier with its corresponding
`arm64musl/server` or `x64musl/server` on Linux. The verifier uses the OpenSSL
CLI to create temporary credentials. The script builds the hello Roc
application for each target against the whole extracted host. For the stand-alone handshake it removes the Roc entry object
from a private archive copy because the C probe supplies its own main. The
probe links the TLS objects from that copy. It needs
neither TLS headers nor a system TLS library at runtime. Run `otool -L` on the
macOS server and inspect Linux program headers and dynamic dependencies with
`readelf -l -d`.

## Build and update contract

The candidate builds with size optimization, the built-in default provider,
OS entropy seeding and architecture-specific assembly. The trial disables
loadable modules, engines and shared libraries. The bundle includes upstream's
Apache-2.0 license alongside the existing nghttp2 license. A candidate update
changes the release version and SHA-256 together, checks upstream advisories
and license changes, and repeats size, linkage and handshake checks on all
three targets. Production adoption also requires the normal host build and
release verification paths to use the pin.
