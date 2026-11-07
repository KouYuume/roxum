# Linux test environment for roxum. tools/linux/test.sh builds it and runs
# the test suite with the repository mounted at /work.
FROM debian:bookworm-slim

ARG ZIG_VERSION=0.16.0
# From https://ziglang.org/download/index.json for ZIG_VERSION.
ARG ZIG_SHA256_AARCH64=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17
ARG ZIG_SHA256_X86_64=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
# Must match .roc-revision; tools/check-roc-toolchain.sh verifies it.
ARG ROC_NIGHTLY=nightly-2026-11-04-2622062
# The release assets' digests for ROC_NIGHTLY; update them with the pin
# (gh api repos/roc-lang/nightlies/releases/tags/<nightly> --jq '.assets[].digest').
ARG ROC_SHA256_ARM64=6ca394307bb09c73ed3acbd52fe3acfea6c5cd065c223e31946f7b304d9a3f60
ARG ROC_SHA256_X86_64=48ad051270b4a6585b3a246ed4f1374cc521ddd1f98b7e11820c6077bcad3071
# Not used in the image: tools/install-roc-nightly.sh reads it for macOS.
ARG ROC_SHA256_MACOS_ARM64=dc510524486b2f04f042187622753af055225c0173bb540bfd63e85c70d2d611

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
