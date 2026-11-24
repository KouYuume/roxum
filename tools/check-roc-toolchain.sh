#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
: "${ROC_SRC:=$HOME/dev/roc/roc}"
: "${ROC_BIN:=roc}"

expected_commit="$(tr -d '[:space:]' < "$repo_root/.roc-revision")"
if [[ ! "$expected_commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo "invalid .roc-revision: expected one full 40-character commit" >&2
    exit 1
fi

# The full-check and release workflows check out Roc; each checkout must use
# the pinned revision. Pull request CI installs the nightly the Dockerfile names.
for workflow in full-checks release; do
    workflow_file="$repo_root/.github/workflows/$workflow.yml"
    ci_commits="$(awk '/repository: roc-lang\/roc/ { in_roc = 1; next } in_roc && /ref:/ { print $2; in_roc = 0 }' "$workflow_file")"
    if [[ -z "$ci_commits" ]]; then
        echo "$workflow.yml does not check out the Roc compiler" >&2
        exit 1
    fi
    for ci_commit in $ci_commits; do
        if [[ "$ci_commit" != "$expected_commit" ]]; then
            echo "$workflow.yml Roc revision does not match .roc-revision: $ci_commit" >&2
            exit 1
        fi
    done
done

# A nightly name carries its commit. A release name does not, and neither does
# its compiler's version, so the pin update checks the release tag's commit.
roc_release="$(sed -n 's/^ARG ROC_RELEASE=//p' "$repo_root/tools/linux/Dockerfile")"
if [[ -z "$roc_release" ]]; then
    echo "tools/linux/Dockerfile does not name a Roc release" >&2
    exit 1
fi
if [[ "$roc_release" == nightly-* && "$roc_release" != nightly-*-"${expected_commit:0:7}" ]]; then
    echo "tools/linux/Dockerfile Roc nightly does not match .roc-revision: $roc_release" >&2
    exit 1
fi

# The Protobuf distribution checks `roc version` against its own record of the
# release, so that record must name the same build.
protobuf_manifest="$repo_root/libraries/roc-protobuf/compatibility.json"
protobuf_release="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["roc_release"])' "$protobuf_manifest")"
if [[ "$protobuf_release" != "$roc_release" ]]; then
    echo "libraries/roc-protobuf/compatibility.json names Roc $protobuf_release, not $roc_release" >&2
    exit 1
fi

if ! git -C "$ROC_SRC" rev-parse --git-dir >/dev/null 2>&1; then
    echo "ROC_SRC does not point to a Roc git checkout: $ROC_SRC" >&2
    exit 1
fi

source_commit="$(git -C "$ROC_SRC" rev-parse HEAD)"
if [[ "$source_commit" != "$expected_commit" ]]; then
    echo "Roc source revision mismatch" >&2
    echo "  expected: $expected_commit" >&2
    echo "  actual:   $source_commit" >&2
    exit 1
fi

compiler_version="$("$ROC_BIN" version)"
if [[ "$compiler_version" != "Roc compiler version $roc_release" ]]; then
    echo "Roc compiler version mismatch" >&2
    echo "  expected: Roc compiler version $roc_release" >&2
    echo "  actual:   $compiler_version" >&2
    exit 1
fi

echo "Roc toolchain pin verified: $expected_commit ($compiler_version)"
