# Toolchain

The source of truth for the Roc compiler revision is [`.roc-revision`](../.roc-revision). Use the Roc nightly built from that revision, named with its SHA-256 values in `tools/linux/Dockerfile`; `tools/install-roc-nightly.sh` installs it, as CI does. The pinned Roc source and roxum host both use Zig 0.17.1. The checks of the ABI glue and the compiler revision also need the source checked out at that revision. Use the same compiler revision locally; a different nightly may change syntax, layout, or the hosted ABI.

## Setup

Install Zig 0.17.1. From the roxum repository, install the pinned Roc nightly, and clone the Roc source at the recorded revision beside it:

```sh
tools/install-roc-nightly.sh ../roc-nightly
git clone https://github.com/roc-lang/roc.git ../roc-compiler
git -C ../roc-compiler checkout "$(cat .roc-revision)"
export ROC_SRC="$(cd ../roc-compiler && pwd)"
export ROC_BIN="$(cd ../roc-nightly && pwd)/roc"
export PATH="$(cd ../roc-nightly && pwd):$PATH"
tools/check-roc-toolchain.sh
```

The supported host targets are `arm64mac`, `arm64musl`, and `x64musl`. See [getting started](guides/getting-started.md) to build the host and an application.

## Updating the pin

Update `.roc-revision`, the source checkout references in the full-check and release workflows, and the nightly and its SHA-256 values in `tools/linux/Dockerfile` (including the macOS one), together. Install the new nightly and verify its revision with `tools/check-roc-toolchain.sh`. Regenerate ABI glue with `tools/regen-glue.sh` and inspect the changes; the generated glue remains tracked.

Run `tools/regen-glue.sh --check`, semantic ABI tests, hosted narrow-integer ABI tests on macOS, unit and contract tests, package identity/manifest tests, integration tests, and E2E tests in all three backends and both allocator modes. Run Linux checks before accepting the update. Rebuild host archives and applications together; do not mix platform sources with an older host ABI.

Roc's glue generation needs a writable compiler cache. Use `ROC_CACHE_DIR` or `XDG_CACHE_HOME` when the default cache is unavailable. Allocation and runtime ABI constraints are documented in [execution and ownership](design/execution-model.md).
