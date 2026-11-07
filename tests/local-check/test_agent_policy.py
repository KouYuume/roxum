"""tools/agent_policy.py: which commands need the maintainer, and how each
agent is told."""
import json
import subprocess
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "tools" / "agent_policy.py"

NEEDS_MAINTAINER = [
    "git push --force origin feature",
    "git push -f origin feature",
    "git push --force-with-lease=feature origin feature",
    "git push origin +feature",
    "git push origin :old-branch",
    "git push --delete origin old-branch",
    "git push origin v0.1.0",
    "git push origin refs/tags/v0.1.0",
    "git push --tags",
    "git push --mirror origin",
    "gh pr merge 12 --merge",
    "gh release create v0.2.0",
    "gh release delete v0.1.0",
    "gh release edit v0.1.0 --draft",
    "gh repo edit --default-branch main",
    "gh repo delete KouYuume/roxum",
    "gh secret set TOKEN",
    "gh workflow run full-checks.yml",
    "gh run rerun 123",
    "gh api -X PUT repos/o/r/branches/main/protection",
    "gh api --method DELETE repos/o/r/git/refs/tags/v0.1.0",
    "gh api repos/o/r/rulesets -f name=x",
    "gh api repos/o/r/rulesets --input ruleset.json",
    "cd /tmp && gh pr merge 3",
]

ALLOWED = [
    "git push origin feature",
    "git push -u origin feature",
    "git status",
    "gh pr create --fill",
    "gh pr view 12",
    "gh pr checks 12",
    "gh release view v0.1.0",
    "gh release list",
    "gh run view 123",
    "gh api repos/o/r/rulesets",
    "gh api -X GET repos/o/r/actions/permissions",
    'git commit -m "gh pr merge and git push --force are not run here"',
    "echo gh release create",
]


def run(agent, command):
    return subprocess.run(["python3", str(SCRIPT), agent], input=json.dumps({"tool_input": {"command": command}}),
                          capture_output=True, text=True)


class AgentPolicy(unittest.TestCase):
    def test_claude_asks_for_operations_that_change_github(self):
        for command in NEEDS_MAINTAINER:
            with self.subTest(command=command):
                result = run("claude", command)
                self.assertEqual(result.returncode, 0)
                decision = json.loads(result.stdout)["hookSpecificOutput"]
                self.assertEqual(decision["permissionDecision"], "ask")

    def test_codex_refuses_operations_that_change_github(self):
        for command in NEEDS_MAINTAINER:
            with self.subTest(command=command):
                result = run("codex", command)
                self.assertEqual(result.returncode, 2)
                self.assertIn("maintainer", result.stderr)

    def test_other_commands_pass_silently(self):
        for agent in ("claude", "codex"):
            for command in ALLOWED:
                with self.subTest(agent=agent, command=command):
                    result = run(agent, command)
                    self.assertEqual((result.returncode, result.stdout), (0, ""))


if __name__ == "__main__":
    unittest.main()
