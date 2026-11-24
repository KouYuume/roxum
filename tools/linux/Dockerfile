# Linux test environment for roxum. tools/linux/test.sh builds it and runs
# the test suite with the repository mounted at /work.
FROM debian:bookworm-slim

ARG ZIG_VERSION=0.17.1
# From https://ziglang.org/download/index.json for ZIG_VERSION.
ARG ZIG_SHA256_AARCH64=a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795
ARG ZIG_SHA256_X86_64=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
# A Roc release (0.1.0_RC1) or nightly (nightly-<date>-<commit>) built from
# .roc-revision; tools/check-roc-toolchain.sh verifies the name.
ARG ROC_RELEASE=0.1.0_RC1
# The release assets' digests for ROC_RELEASE; update them with the pin
# (gh api repos/roc-lang/roc/releases/tags/<release> --jq '.assets[].digest',
# or repos/roc-lang/nightlies/... for a nightly).
ARG ROC_SHA256_ARM64=b3e0a9dbc922f3802702a55a1869ad2c2e4f4dc935d8a9d1b26c3612668dff43
ARG ROC_SHA256_X86_64=043c426ea85dcdbd427951eaed246f0c10c171d988f2598782233a6dae43379d
# Not used in the image: tools/install-roc.sh reads it for macOS.
ARG ROC_SHA256_MACOS_ARM64=e8228040c701e130254c72539a1d0f1b150d78c00058747edb0edae51ba5dbc8

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash build-essential bzip2 cmake ninja-build libdigest-sha-perl ca-certificates curl git libssl-dev openssl postgresql procps python3 python3-venv xz-utils \
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
    && case "$ROC_RELEASE" in \
        nightly-*) roc_url="https://github.com/roc-lang/nightlies/releases/download/${ROC_RELEASE}/roc_nightly-${roc_arch}-${ROC_RELEASE#nightly-}.tar.gz" ;; \
        *) roc_url="https://github.com/roc-lang/roc/releases/download/${ROC_RELEASE}/roc-${roc_arch}-${ROC_RELEASE}.tar.gz" ;; \
    esac \
    && mkdir -p /opt/roc \
    && curl -fsSL -o /tmp/roc.tar.gz "$roc_url" \
    && echo "${roc_sha256}  /tmp/roc.tar.gz" | sha256sum -c - \
    && tar -xz -C /opt/roc --strip-components=1 -f /tmp/roc.tar.gz \
    && rm /tmp/roc.tar.gz \
    && ln -s /opt/roc/roc /usr/local/bin/roc

WORKDIR /work
