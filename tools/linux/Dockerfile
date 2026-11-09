# Linux test environment for roxum. tools/linux/test.sh builds it and runs
# the test suite with the repository mounted at /work.
FROM debian:bookworm-slim

ARG ZIG_VERSION=0.17.1
# From https://ziglang.org/download/index.json for ZIG_VERSION.
ARG ZIG_SHA256_AARCH64=a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795
ARG ZIG_SHA256_X86_64=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
# Must match .roc-revision; tools/check-roc-toolchain.sh verifies it.
ARG ROC_NIGHTLY=nightly-2026-11-09-9e85de7
# The release assets' digests for ROC_NIGHTLY; update them with the pin
# (gh api repos/roc-lang/nightlies/releases/tags/<nightly> --jq '.assets[].digest').
ARG ROC_SHA256_ARM64=9c12d85abce8aa36daed9ffe04c75fe00c67b0fc939647899493500a1a3b5eff
ARG ROC_SHA256_X86_64=9d2480e900bee27cae0974266c088f43e8e2ceaa6543c2be7314b7bdd2b7891d
# Not used in the image: tools/install-roc-nightly.sh reads it for macOS.
ARG ROC_SHA256_MACOS_ARM64=0e12e15c1c1d0af817c1f27b0f103a6502c2b3aea587f1de7d7df312642d74d3

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash ca-certificates curl git openssl postgresql procps python3 xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Downloads are checked against pinned digests before they are unpacked.
RUN arch="$(uname -m)" \
    && case "$arch" in \
        aarch64) zig_sha256="$ZIG_SHA256_AARCH64" ;; \
        x86_64) zig_sha256="$ZIG_SHA256_X86_64" ;; \
        *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz" \
    && echo "${zig_sha256}  /tmp/zig.tar.xz" | sha256sum -c - \
    && tar -xJ -C /opt -f /tmp/zig.tar.xz \
    && rm /tmp/zig.tar.xz \
    && ln -s "/opt/zig-${arch}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig

RUN case "$(uname -m)" in \
        aarch64) roc_arch=linux_arm64; roc_sha256="$ROC_SHA256_ARM64" ;; \
        x86_64) roc_arch=linux_x86_64; roc_sha256="$ROC_SHA256_X86_64" ;; \
        *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac \
    && date_commit="${ROC_NIGHTLY#nightly-}" \
    && mkdir -p /opt/roc \
    && curl -fsSL -o /tmp/roc.tar.gz "https://github.com/roc-lang/nightlies/releases/download/${ROC_NIGHTLY}/roc_nightly-${roc_arch}-${date_commit}.tar.gz" \
    && echo "${roc_sha256}  /tmp/roc.tar.gz" | sha256sum -c - \
    && tar -xz -C /opt/roc --strip-components=1 -f /tmp/roc.tar.gz \
    && rm /tmp/roc.tar.gz \
    && ln -s /opt/roc/roc /usr/local/bin/roc

WORKDIR /work
