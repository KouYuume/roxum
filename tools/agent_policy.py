#!/usr/bin/env python3
"""PreToolUse hook for coding agents: operations that change GitHub, or
rewrite what was pushed, need the maintainer.

    tools/agent_policy.py claude   ask the maintainer before running them
    tools/agent_policy.py codex    refuse them (Codex hooks cannot ask)

Covered: `git push` that forces, deletes, mirrors, or pushes tags; `gh pr
merge`; `gh release` other than reading; changing the repository, its
secrets, variables, or workflows with `gh`; and `gh api` requests other than
GET. The repository rulesets refuse direct pushes and unchecked merges on
GitHub's side as well (docs/contributing.md).
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_local_check import git_subcommand, simple_commands  # noqa: E402

FORCING = {"-f", "--force", "--force-with-lease", "--force-if-includes", "--mirror", "--delete", "-d",
           "--tags", "--follow-tags", "--prune"}
READING_RELEASE = {"list", "view", "download"}
GH_CHANGES = {
    "repo": {"edit", "delete", "rename", "archive", "unarchive", "sync"},
    "secret": {"set", "delete"},
    "variable": {"set", "delete"},
    "workflow": {"run", "enable", "disable"},
    "run": {"cancel", "rerun", "delete"},
    "ruleset": set(),
    "label": {"create", "edit", "delete", "clone"},
}
API_BODY = {"-f", "-F", "--field", "--raw-field", "--input"}


def git_push_reason(arguments):
    for argument in arguments:
        if argument in FORCING or argument.startswith("--force-with-lease=") or argument.startswith("--push-option"):
            return f"`git push {argument}` rewrites or deletes what was pushed, or pushes tags"
        if argument.startswith("+"):
            return f"`{argument}` force-pushes"
        if argument.startswith(":") or argument.startswith("refs/tags/") or re.match(r"^v\d+\.\d+\.\d+$", argument):
            return f"`{argument}` deletes a branch or pushes a tag"
    return None


def gh_reason(arguments):
    if len(arguments) < 1:
        return None
    group, action = arguments[0], arguments[1] if len(arguments) > 1 else ""
    if group == "pr" and action == "merge":
        return "`gh pr merge` merges a pull request"
    if group == "release" and action not in READING_RELEASE:
        return f"`gh release {action}` changes a release"
    if group in GH_CHANGES and (action in GH_CHANGES[group] or not GH_CHANGES[group]):
        return f"`gh {group} {action}` changes the repository"
    if group == "api":
        method = "GET"
        for index, argument in enumerate(arguments):
            if argument in ("-X", "--method") and index + 1 < len(arguments):
                method = arguments[index + 1].upper()
            elif argument.startswith("--method="):
                method = argument.split("=", 1)[1].upper()
            elif argument.startswith("-X") and len(argument) > 2:
                method = argument[2:].upper()
            elif argument in API_BODY and method == "GET":
                method = "POST"  # gh api sends a body with POST unless told otherwise
        if method != "GET":
            return f"`gh api` with {method} changes GitHub"
    return None


def reason_for(command):
    for argv in simple_commands(command):
        program = Path(argv[0]).name
        if program == "git":
            subcommand, _, rest = git_subcommand(argv[1:])
            if subcommand == "push":
                found = git_push_reason(rest)
                if found:
                    return found
        elif program == "gh":
            found = gh_reason(argv[1:])
            if found:
                return found
    return None


def main():
    agent = sys.argv[1] if len(sys.argv) > 1 else ""
    if agent not in ("claude", "codex"):
        print(__doc__, file=sys.stderr)
        return 64
    try:
        event = json.load(sys.stdin)
    except ValueError:
        return 0
    command = (event.get("tool_input") or {}).get("command")
    if not isinstance(command, str):
        return 0
    found = reason_for(command)
    if not found:
        return 0
    if agent == "claude":
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "ask",
            "permissionDecisionReason": f"{found}; the maintainer decides",
        }}))
        return 0
    print(f"agent policy: {found}; ask the maintainer to run it", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
