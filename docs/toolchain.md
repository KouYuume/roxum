# Toolchain

The source of truth for the Roc compiler revision is [`.roc-revision`](../.roc-revision). Use the Roc build from that revision that `tools/linux/Dockerfile` names in `ROC_RELEASE`, with its SHA-256 values: a release such as `0.1.0_RC1`, or a nightly such as `nightly-2026-11-09-9e85de7`. `tools/install-roc.sh` installs it, as CI does. The pinned Roc source and roxum host both use Zig 0.17.1. The checks of the ABI glue and the compiler revision also need the source checked out at that revision. Use the same compiler revision locally; a different build may change syntax, layout, or the hosted ABI.

## Python test dependencies

The full-check workflow selects CPython 3.13 on macOS and Linux. Use that version
when reproducing CI: the gRPC and Protobuf checks install pinned, hash-verified
binary wheels, whose Python compatibility is independent of the Roc compiler.
Do not rely on the runner image's default Python. After changing Python versions,
recreate the test venvs under `zig-out/` so they use the selected interpreter.

## Setup

Host builds use CMake, Ninja, Python 3, curl, shasum and tar with bzip2 support to build the pinned Mbed TLS release with Zig. Applications using a published bundle only need Roc.

Install Zig 0.17.1. From the roxum repository, install the pinned Roc build, and clone the Roc source at the recorded revision beside it:

```sh
tools/install-roc.sh ../roc-bin
git clone https://github.com/roc-lang/roc.git ../roc-compiler
git -C ../roc-compiler checkout "$(cat .roc-revision)"
export ROC_SRC="$(cd ../roc-compiler && pwd)"
export ROC_BIN="$(cd ../roc-bin && pwd)/roc"
export PATH="$(cd ../roc-bin && pwd):$PATH"
tools/check-roc-toolchain.sh
```

The supported host targets are `arm64mac`, `arm64musl`, and `x64musl`. See [getting started](guides/getting-started.md) to build the host and an application.

## Updating the pin

Update `.roc-revision`, the source checkout references in the full-check and release workflows, and `ROC_RELEASE` and its SHA-256 values in `tools/linux/Dockerfile` (including the macOS one), together. A nightly's name carries its commit, which `tools/check-roc-toolchain.sh` compares with `.roc-revision`. A release's name and its `roc version` do not, so check that the release tag points at `.roc-revision` (`gh api repos/roc-lang/roc/git/ref/tags/<release> --jq .object.sha`). Install the new build and verify it with `tools/check-roc-toolchain.sh`. Regenerate ABI glue with `tools/regen-glue.sh` and inspect the changes; the generated glue remains tracked.

Run `tools/regen-glue.sh --check`, semantic ABI tests, hosted narrow-integer ABI tests on macOS, unit and contract tests, package identity/manifest tests, integration tests, and E2E tests in all three backends and both allocator modes. Run Linux checks before accepting the update. Rebuild host archives and applications together; do not mix platform sources with an older host ABI.

Roc's glue generation needs a writable compiler cache. Use `ROC_CACHE_DIR` or `XDG_CACHE_HOME` when the default cache is unavailable. Allocation and runtime ABI constraints are documented in [execution and ownership](design/execution-model.md).
