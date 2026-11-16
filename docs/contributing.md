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

- `main` and `develop` change only through pull requests whose `fast checks` and `dependency checks` passed, merged with a merge commit. For `develop`, the checks must have passed on top of its latest commit: when `develop` moves, update the pull request and let the checks run again. The branches cannot be force-pushed or deleted. Pull requests need no approval, so the maintainer can merge their own.
- Release tags `v*` cannot be moved or deleted. The release workflow creates them.
- Workflows from forks run only after the maintainer approves them. The workflow token reads by default and cannot approve pull requests.
- Auto-merge is allowed, for the Dependabot updates described in [Dependency updates](#dependency-updates). Dependabot alerts and security updates are on.

## CI

| Workflow | When | What |
|---|---|---|
| [`ci.yml`](../.github/workflows/ci.yml) | Pull requests and pushes to `develop` | On Linux: the action lockfile, release metadata and changelog, the hook tests, `zig build test`, and the E2E tests in the dev backend; it reports success at once when only Markdown other than the changelog changed |
| [`full-checks.yml`](../.github/workflows/full-checks.yml) | Before each release, and by hand from the Actions tab | Every check on macOS and Linux, including the ones `tools/check.py` leaves out: the reverse proxy check (Caddy), the ownership contract suite, the hosted-integer ABI check, and the httparse comparison |
| [`release.yml`](../.github/workflows/release.yml) | Merges into `main` | The full checks, then the release ([versioning](design/versioning.md#releasing)) |
| [`dependency-checks.yml`](../.github/workflows/dependency-checks.yml) | Pull requests and pushes to `develop`, and by hand | `dependency checks`: tests the auto-merge policy, then audits with `cargo audit`, builds, and tests the Cargo projects (`tools/axum-contract`, `tools/http1-differential`, `bench/m13/axum`) a pull request changed, or all of them on a push, by hand, or when a pull request changes this workflow |
| [`dependency-audit.yml`](../.github/workflows/dependency-audit.yml) | Daily at 00:00 JST, and by hand | `cargo audit` of every Cargo lockfile, so advisories for lockfiles nobody changed still surface |
| [`dependabot-auto-merge.yml`](../.github/workflows/dependabot-auto-merge.yml) | Dependabot pull requests | Reserves auto-merge for the updates in [Dependency updates](#dependency-updates), and takes back its reservation from any other |

The local record covers the platform where you ran the checks. Linux differences surface in the full checks before a release; run `tools/linux/test.sh` to check Linux locally in a container.

## Dependency updates

[`.github/dependabot.yml`](../.github/dependabot.yml) covers the Cargo projects above and the GitHub Actions in the workflows. The pinned Roc nightly and Zig are not covered; update them by hand ([toolchain.md](toolchain.md)). Neither is the base image of `tools/linux/Dockerfile`: the floating tag `debian:bookworm-slim` takes in the latest image on each build.

- Version updates arrive on the 1st of each month at 09:00 JST. Minor and patch updates come together in one pull request per directory, each major update in its own, and only releases at least 7 days old (14 for a major Cargo update) are offered. At most two version update pull requests per directory stay open.
- Security updates arrive as soon as GitHub knows a fix, without waiting for the schedule. Patch and minor fixes come together in one pull request per directory, a major fix in its own.

[`dependabot-auto-merge.yml`](../.github/workflows/dependabot-auto-merge.yml) reserves auto-merge only for a pull request that [`.github/scripts/dependabot-auto-merge.cjs`](../.github/scripts/dependabot-auto-merge.cjs) accepts:

- a Cargo security update in the `cargo-security-compatible` group, with patch and minor updates only,
- changes to the `Cargo.lock` of the three Cargo projects and nothing else, so every update stays within the requirements in `Cargo.toml`,
- a single commit that Dependabot wrote and GitHub verified, in this repository, targeting `develop`,
- and a repository where the rulesets require both checks on top of the latest `develop` and allow auto-merge.

GitHub then merges it with a merge commit once `fast checks` and `dependency checks` pass on top of the latest `develop`. Dependabot does not rebase a pull request only because `develop` moved: comment `@dependabot rebase` on it, and the workflow evaluates the new commit and reserves the merge again. Do not use Update branch, which adds a merge commit of your own and makes the update one a person reviews. The merge is made with the workflow token, so the push to `develop` it causes starts no workflow; the checks already ran on the same tree. The maintainer reviews and merges every other update: version updates, major updates, security updates that rewrite a requirement in `Cargo.toml` (such as the pinned `axum =0.8.9` and `httparse =1.10.1` the comparisons use, or a 0.x minor update), GitHub Actions updates, and any pull request with a commit added by hand. The policy script is read from `develop`, never from the pull request. When you rename a group, a directory, the branch, or a required check, change `dependabot.yml`, the policy script, its tests, and the rulesets together.

When an update does not arrive, look at the update log in Insights → Dependency graph → Dependabot: the schedule, the cooldown, and the open pull request limit can hold it back, and a security update needs a fixed version. When the daily audit fails without a fixed version, decide how to handle the advisory; pull requests that change that Cargo project fail `dependency checks` until then.

When the workflow fails or is cancelled, it takes back the reservation it made. To stop auto-merge, first disable auto-merge on the open Dependabot pull requests, then disable the Dependabot auto-merge workflow in the Actions tab, and check again that no reservation is left. Disabling the workflow alone keeps existing reservations. Update pull requests, alerts, and the audit go on.

### Action lockfile

Workflows refer to actions by full version tags such as `actions/checkout@v7.0.1`, and [`.github/workflows/actions.lock`](../.github/workflows/actions.lock) pins each of them, with the actions they use in turn, to a commit and to the IDs of its owner and repository. Do not edit the lockfile by hand. After adding, removing, or changing a `uses:` line, install the [gh-actions-lock](https://github.com/github/gh-actions-lock) extension (`gh extension install github/gh-actions-lock`), run `gh actions-lock` from the repository root, and commit the workflow and the lockfile together; `fast checks` runs `gh actions-lock --verify` and fails when they disagree. Dependabot regenerates the lockfile in its GitHub Actions update pull requests. When reviewing a lockfile change, read the code behind every changed `commit`, and do not merge a change to `owner_id` or `repo_id` until you know why it changed: an ordinary update keeps both, and a different value means the name now leads to a different repository. The call of `./.github/workflows/full-checks.yml` from `release.yml` needs no entry, because it runs from the same commit, and the actions inside `full-checks.yml` have their own entries. The extension that `fast checks` installs is outside the lockfile and is pinned by its release tag.
