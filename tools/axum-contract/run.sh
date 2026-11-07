#!/usr/bin/env bash
# Compares roxum's HTTP contract with axum 0.8.9's. Needs cargo, so it is apart
# from the release gate, as the httparse differential is.
set -euo pipefail

directory="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$directory/../.." && pwd)"
cd "$repo_root"
cargo build --locked --release --quiet --manifest-path "$directory/Cargo.toml"
roc build --opt=speed --output="$directory/target/roxum-app" "$directory/app.roc"
python3 "$directory/compare.py" "$directory/target/release/roxum-axum-contract" "$directory/target/roxum-app"
