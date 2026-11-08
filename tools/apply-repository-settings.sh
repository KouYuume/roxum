#!/usr/bin/env bash
# Applies the GitHub settings and the rulesets in .github/rulesets/ to the
# repository (docs/contributing.md). The maintainer runs it after the first
# push of main and develop, and again after changing a ruleset file. A ruleset
# is matched by name: an existing one is replaced, a new one is created.
#   tools/apply-repository-settings.sh <owner>/<repository>
set -euo pipefail

repo=${1:?usage: tools/apply-repository-settings.sh <owner>/<repository>}
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Merge commits only: a release merges develop into main as it is. Auto-merge
# lets dependabot-auto-merge.yml reserve a merge until the required checks pass.
gh api -X PATCH "repos/$repo" \
    -F allow_merge_commit=true -F allow_squash_merge=false -F allow_rebase_merge=false \
    -F allow_auto_merge=true -F delete_branch_on_merge=false >/dev/null
echo "merge methods: merge commits only, auto-merge allowed"

# Dependabot alerts, and security updates that open a pull request for a fix
# (.github/dependabot.yml groups them).
gh api -X PUT "repos/$repo/vulnerability-alerts" >/dev/null
gh api -X PUT "repos/$repo/automated-security-fixes" >/dev/null
echo "Dependabot: alerts and security updates on"

# Workflows from forks run only after the maintainer approves them.
gh api -X PUT "repos/$repo/actions/permissions/fork-pr-contributor-approval" \
    -f approval_policy=all_external_contributors
echo "fork pull requests: workflows wait for approval"

# The workflow token reads by default; release.yml asks for write itself.
gh api -X PUT "repos/$repo/actions/permissions/workflow" \
    -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
echo "workflow token: read, cannot approve pull requests"

for file in .github/rulesets/*.json; do
    name=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["name"])' "$file")
    id=$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$name\") | .id")
    if [[ -n "$id" ]]; then
        gh api -X PUT "repos/$repo/rulesets/$id" --input "$file" >/dev/null
    else
        gh api -X POST "repos/$repo/rulesets" --input "$file" >/dev/null
    fi
    echo "ruleset: $name"
done
