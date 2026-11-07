#!/usr/bin/env bash
# Runs a command in a Linux container with this repository mounted at /work.
# Without arguments it runs the Linux test suite (run-tests.sh).
#   tools/linux/test.sh
#   tools/linux/test.sh zig build test-m11a
# The container uses the host's architecture (arm64 on Apple silicon). Zig and
# Roc caches persist in the roxum-linux-cache volume.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
image=roxum-linux

docker build --quiet -t "$image" -f "$repo_root/tools/linux/Dockerfile" "$repo_root/tools/linux" >/dev/null

if [[ $# -eq 0 ]]; then
    set -- tools/linux/run-tests.sh
fi

tty_flags=()
if [[ -t 0 && -t 1 ]]; then
    tty_flags=(-it)
fi

# Build outputs under the mounted tree are per-OS; keep Linux's apart from
# the macOS ones by giving the container its own zig-out and .zig-cache.
exec docker run --rm ${tty_flags[@]+"${tty_flags[@]}"} \
    -v "$repo_root:/work" \
    -v roxum-linux-cache:/cache \
    -v roxum-linux-zig-out:/work/zig-out \
    -v roxum-linux-zig-local-cache:/work/.zig-cache \
    -e ZIG_GLOBAL_CACHE_DIR=/cache/zig \
    -e XDG_CACHE_HOME=/cache/xdg \
    -e HOME=/cache/home \
    "$image" "$@"
