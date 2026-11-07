#!/usr/bin/env bash
# Builds the three comparison servers for one platform into bench/m13/out/<platform>/.
#   bench/m13/build.sh macos    # roxum and axum natively; Go through the golang image
#   bench/m13/build.sh linux    # inside tools/linux/test.sh: roxum only
#   bench/m13/build.sh linux-deps   # on the Docker host: axum and Go for linux/arm64
set -euo pipefail

bench_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$bench_dir/../.." && pwd)"
platform="${1:?usage: build.sh macos|linux|linux-deps|linux-native}"
out="$bench_dir/out/$platform"
mkdir -p "$out"
cd "$repo_root"

build_roxum() {
    zig build host
    roc build --opt=speed --output="$1/roxum" bench/m13/app.roc >/dev/null
}

resolve_image() {
    local requested="$1"
    if ! docker image inspect "$requested" >/dev/null 2>&1; then
        docker pull "$requested" >&2
    fi
    docker image inspect "$requested" --format '{{index .RepoDigests 0}}'
}

manifest_args=()
case "$platform" in
    macos)
        build_roxum "$out"
        cargo build --locked --release --manifest-path bench/m13/axum/Cargo.toml
        cp bench/m13/axum/target/release/roxum-bench-axum "$out/axum"
        go_image="$(resolve_image "${GO_IMAGE:-golang:1.23}")"
        manifest_args+=(--go-image "$go_image")
        docker run --rm -v "$bench_dir/go:/src" -v "$out:/out" -w /src \
            -e GOOS=darwin -e GOARCH=arm64 -e CGO_ENABLED=0 "$go_image" go build -o /out/go .
        ;;
    linux)
        build_roxum "$bench_dir/out/linux"
        ;;
    linux-deps)
        out="$bench_dir/out/linux"
        mkdir -p "$out"
        rust_image="$(resolve_image "${RUST_IMAGE:-rust:1}")"
        manifest_args+=(--rust-image "$rust_image")
        docker run --rm -v "$bench_dir/axum:/src" -v "$out:/out" -w /src "$rust_image" \
            bash -c 'cargo build --locked --release --target-dir /tmp/target && cp /tmp/target/release/roxum-bench-axum /out/axum'
        go_image="$(resolve_image "${GO_IMAGE:-golang:1.23}")"
        manifest_args+=(--go-image "$go_image")
        docker run --rm -v "$bench_dir/go:/src" -v "$out:/out" -w /src \
            -e CGO_ENABLED=0 "$go_image" go build -o /out/go .
        ;;
    linux-native)
        [[ "$(uname -s)" == Linux ]] || { echo "linux-native requires Linux" >&2; exit 2; }
        : "${BENCH_TOOLCHAIN_LOCK:?set BENCH_TOOLCHAIN_LOCK to the frozen Linux toolchain JSON}"
        python3 "$bench_dir/toolchain_lock.py" check "$BENCH_TOOLCHAIN_LOCK"
        build_roxum "$out"
        cargo build --locked --release --manifest-path bench/m13/axum/Cargo.toml
        cp bench/m13/axum/target/release/roxum-bench-axum "$out/axum"
        (cd "$bench_dir/go" && CGO_ENABLED=0 go build -o "$out/go" .)
        ;;
    *)
        echo "usage: bench/m13/build.sh macos|linux|linux-deps|linux-native" >&2
        exit 2
        ;;
esac

python3 "$bench_dir/provenance.py" "$out" "$platform" "${manifest_args[@]}"
if [[ "$platform" == linux-native ]]; then
    python3 "$bench_dir/toolchain_lock.py" check "$BENCH_TOOLCHAIN_LOCK"
    cp "$BENCH_TOOLCHAIN_LOCK" "$out/toolchain-lock.json"
fi
