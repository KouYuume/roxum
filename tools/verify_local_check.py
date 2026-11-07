#!/usr/bin/env python3
"""Keeps unverified commits from leaving this machine.

The release checks run locally (tools/check.py). When all of them pass on a
clean tree, check.py records that tree in zig-out/check-passed.json. Pull
request CI then runs only a fast subset, and the full checks run before a
release (docs/contributing.md).

    tools/verify_local_check.py pre-push     git pre-push hook (.githooks/pre-push):
                                             refuses to push a commit whose tree
                                             has not passed
    tools/verify_local_check.py agent-hook   PreToolUse hook for Claude Code and
                                             Codex: refuses `gh pr create` for an
                                             unverified HEAD, and pushes that skip
                                             or replace the pre-push hook

A commit passes when its tree is the recorded tree, or differs from it only in
Markdown files other than CHANGELOG.md, which no check reads.
"""
import json
import re
import shlex
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RECORD = ROOT / "zig-out" / "check-passed.json"
HOOKS_PATH = ".githooks"
ZERO = re.compile(r"^0+$")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
RUN_CHECKS = "run `python3 tools/check.py` with ROC_SRC set on a clean tree, then retry"


def git(*arguments):
    return subprocess.run(["git", *arguments], cwd=ROOT, check=True, capture_output=True, text=True).stdout.strip()


def unchecked_files(commit):
    """The files of the commit's tree that differ from the tree that passed,
    leaving out Markdown files that no check reads; None when nothing passed."""
    if not RECORD.exists():
        return None
    record = json.loads(RECORD.read_text())
    tree = git("rev-parse", f"{commit}^{{tree}}")
    if tree == record["tree"]:
        return []
    try:
        changed = git("diff", "--name-only", record["tree"], tree).splitlines()
    except subprocess.CalledProcessError:
        return None  # the tree that passed is gone from this repository
    return [path for path in changed if not path.endswith(".md") or path == "CHANGELOG.md"]


def problem(commit):
    """Why the commit may not leave, or None."""
    files = unchecked_files(commit)
    if files is None:
        return f"no local check has passed; {RUN_CHECKS}"
    if files:
        shown = ", ".join(files[:5]) + (", ..." if len(files) > 5 else "")
        return f"{commit[:12]} differs from the tree that passed the local checks ({shown}); {RUN_CHECKS}"
    return None


def pre_push(lines):
    failures = []
    for line in lines:
        parts = line.split()
        if len(parts) != 4 or ZERO.match(parts[1]):
            continue  # a deletion
        commit = git("rev-parse", f"{parts[1]}^{{commit}}")
        found = problem(commit)
        if found:
            failures.append(f"{parts[0]}: {found}")
    for failure in failures:
        print(f"pre-push: {failure}", file=sys.stderr)
    return 1 if failures else 0


def agent_hook(event):
    command = (event.get("tool_input") or {}).get("command") or ""
    if not isinstance(command, str):
        return 0
    for argv in simple_commands(command):
        program = Path(argv[0]).name if argv else ""
        if program == "git":
            subcommand, settings, rest = git_subcommand(argv[1:])
            if subcommand != "push":
                continue
            if "--no-verify" in rest or any(setting.lower().startswith("core.hookspath") for setting in settings):
                return deny("pushes must run the pre-push hook; do not pass --no-verify or override core.hooksPath")
            if git_config("core.hooksPath") != HOOKS_PATH:
                return deny(f"the pre-push hook is not installed; run `git config core.hooksPath {HOOKS_PATH}` first")
        elif program == "gh" and argv[1:3] == ["pr", "create"]:
            found = problem(git("rev-parse", "HEAD"))
            if found:
                return deny(found)
    return 0


def simple_commands(command):
    """The argument lists of the simple commands in a shell command line,
    split at `;`, `&&`, `||`, `|`, `&`, and parentheses, without leading
    variable assignments. Quoted text, such as a commit message, stays one
    argument."""
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()")
    lexer.whitespace_split = True
    try:
        tokens = list(lexer)
    except ValueError:
        tokens = command.split()  # unbalanced quotes: judge the words
    commands, current = [], []
    for token in tokens + [";"]:
        if token and set(token) <= set(";&|()"):
            while current and ASSIGNMENT.match(current[0]):
                current.pop(0)
            if current:
                commands.append(current)
            current = []
        else:
            current.append(token)
    return commands


def git_subcommand(arguments):
    """git's subcommand, the `-c` settings before it, and its arguments."""
    settings = []
    index = 0
    while index < len(arguments) and arguments[index].startswith("-"):
        option = arguments[index]
        if option in ("-c", "-C", "--git-dir", "--work-tree", "--namespace", "--config-env"):
            if option == "-c" and index + 1 < len(arguments):
                settings.append(arguments[index + 1])
            index += 2
            continue
        if option.startswith("--config-env="):
            settings.append(option.split("=", 1)[1])
        index += 1
    if index >= len(arguments):
        return None, settings, []
    return arguments[index], settings, arguments[index + 1:]


def git_config(name):
    result = subprocess.run(["git", "config", "--get", name], cwd=ROOT, capture_output=True, text=True)
    return result.stdout.strip()


def deny(reason):
    # Exit status 2 with the reason on stderr blocks the tool call in both
    # Claude Code and Codex.
    print(f"local checks: {reason}", file=sys.stderr)
    return 2


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "pre-push":
        return pre_push(sys.stdin.read().splitlines())
    if mode == "agent-hook":
        try:
            event = json.load(sys.stdin)
        except ValueError:
            return 0
        return agent_hook(event)
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main())
