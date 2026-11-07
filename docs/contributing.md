# Contributing

The full checks build every test application in every Roc backend and allocator mode. They run on your machine before you push, so pull request CI only needs a fast subset.

## Setup

Set up the toolchain as in [toolchain.md](toolchain.md), with `ROC_SRC` pointing at a Roc checkout at [`.roc-revision`](../.roc-revision). Then enable the pre-push hook once per clone:

```sh
git config core.hooksPath .githooks
```

## Before pushing

Commit your changes, then run the full checks on the clean tree:

```sh
ROC_SRC=<roc checkout> python3 tools/check.py
```

When every check passes, `tools/check.py` records the tree in `zig-out/check-passed.json`. The pre-push hook refuses commits whose tree differs from the recorded one. Changes to Markdown files other than `CHANGELOG.md` are exempt, because no check reads them. Rewording or rebasing a commit does not require a new run if the tree stays the same.

Do not bypass the hook with `git push --no-verify` or by overriding `core.hooksPath`.

## Coding agents

Claude Code (`.claude/settings.json`) and Codex (`.codex/hooks.json`) run two hooks before shell commands. Codex loads project hooks only after you trust them with `/hooks`.

- `tools/verify_local_check.py` refuses `gh pr create` for an unverified `HEAD`, pushes while the pre-push hook is not enabled, and pushes that skip the hook.
- `tools/agent_policy.py` leaves operations that change GitHub or rewrite what was pushed to the maintainer: merging pull requests, changing releases, repository settings, secrets, variables, or workflow runs with `gh`, `gh api` requests other than GET, and pushes that force, delete, mirror, or push tags. Claude Code asks the maintainer before running one; Codex refuses it, and the maintainer runs it by hand.

## Repository rules

[`tools/apply-repository-settings.sh`](../tools/apply-repository-settings.sh) applies these settings, and the rulesets in [`.github/rulesets/`](../.github/rulesets/), with no exceptions for anyone, including the maintainer:

- `main` and `develop` change only through pull requests whose `fast checks` passed, merged with a merge commit. They cannot be force-pushed or deleted. Pull requests need no approval, so the maintainer can merge their own.
- Release tags `v*` cannot be moved or deleted. The release workflow creates them.
- Workflows from forks run only after the maintainer approves them. The workflow token reads by default and cannot approve pull requests.

## CI

| Workflow | When | What |
|---|---|---|
| [`ci.yml`](../.github/workflows/ci.yml) | Pull requests and pushes to `develop` | On Linux: release metadata and changelog, the hook tests, `zig build test`, and the E2E tests in the dev backend; it reports success at once when only Markdown other than the changelog changed |
| [`full-checks.yml`](../.github/workflows/full-checks.yml) | Before each release, and by hand from the Actions tab | Every check on macOS and Linux, including the ones `tools/check.py` leaves out: the reverse proxy check (Caddy), the ownership contract suite, the hosted-integer ABI check, and the httparse comparison |
| [`release.yml`](../.github/workflows/release.yml) | Merges into `main` | The full checks, then the release ([versioning](design/versioning.md#releasing)) |

The local record covers the platform where you ran the checks. Linux differences surface in the full checks before a release; run `tools/linux/test.sh` to check Linux locally in a container.
