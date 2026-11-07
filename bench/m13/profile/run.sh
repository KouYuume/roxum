#!/usr/bin/env bash
# Runs a command in the profiling container with the repository at /work.
#   bench/m13/profile/run.sh python3 bench/m13/instructions.py /oha out.json roxum=bench/m13/out/linux/roxum
# OHA_BINARY names a Linux oha for the container's architecture; it is mounted at /oha.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
oha="${OHA_BINARY:-$repo_root/bench/m13/out/linux/oha-install/bin/oha}"
[[ -x "$oha" ]] || { echo "no Linux oha at $oha (set OHA_BINARY)" >&2; exit 2; }

docker build --quiet -t roxum-linux -f "$repo_root/tools/linux/Dockerfile" "$repo_root/tools/linux" >/dev/null
docker build --quiet -t roxum-linux-profile "$repo_root/bench/m13/profile" >/dev/null

exec docker run --rm \
    -v "$repo_root:/work" \
    -v "$oha:/oha:ro" \
    -v roxum-linux-cache:/cache \
    -v roxum-linux-zig-out:/work/zig-out \
    -v roxum-linux-zig-local-cache:/work/.zig-cache \
    -e ZIG_GLOBAL_CACHE_DIR=/cache/zig \
    -e XDG_CACHE_HOME=/cache/xdg \
    -e HOME=/cache/home \
    -w /work \
    roxum-linux-profile "$@"
