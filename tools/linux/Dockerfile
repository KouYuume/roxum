# Linux test environment for roxum. tools/linux/test.sh builds it and runs
# the test suite with the repository mounted at /work.
FROM debian:bookworm-slim

ARG ZIG_VERSION=0.17.1
# From https://ziglang.org/download/index.json for ZIG_VERSION.
ARG ZIG_SHA256_AARCH64=a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795
ARG ZIG_SHA256_X86_64=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a
# A Roc release (0.1.0-RC2) or nightly (nightly-<date>-<commit>) built from
# .roc-revision; tools/check-roc-toolchain.sh verifies the name.
ARG ROC_RELEASE=0.1.0-RC2
# The release assets' digests for ROC_RELEASE; update them with the pin
# (gh api repos/roc-lang/roc/releases/tags/<release> --jq '.assets[].digest',
# or repos/roc-lang/nightlies/... for a nightly).
ARG ROC_SHA256_ARM64=79ad3dcd6655c83e9f64dc875b934056f0815e1e46569fc44aed6c8026a531a8
ARG ROC_SHA256_X86_64=12a1b5f2c5b02ad87c8ad2afecf5af2c195baf5b004492bddd40bd5398f8f3bb
# Not used in the image: tools/install-roc.sh reads it for macOS.
ARG ROC_SHA256_MACOS_ARM64=50e044ad7d44a4c175ad6ac9c642ab9b82a2fbd3b9da207a33ec1f4c7939d1d2

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
