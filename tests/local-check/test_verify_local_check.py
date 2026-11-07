"""tools/verify_local_check.py in a scratch repository: which commits may be
pushed, and which agent commands are refused."""
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "tools" / "verify_local_check.py"
ZERO = "0" * 40


class LocalCheck(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        (self.root / "tools").mkdir()
        shutil.copy(SCRIPT, self.root / "tools" / "verify_local_check.py")
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.com")
        self.git("config", "user.name", "test")
        self.write(".gitignore", "zig-out/\n")
        self.write("app.roc", "app\n")
        self.write("README.md", "readme\n")
        self.write("CHANGELOG.md", "# Changelog\n")
        self.commit("first")

    def tearDown(self):
        self.directory.cleanup()

    def git(self, *arguments):
        return subprocess.run(["git", *arguments], cwd=self.root, check=True, capture_output=True, text=True).stdout.strip()

    def write(self, name, text):
        (self.root / name).write_text(text)

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def record_pass(self):
        record = self.root / "zig-out" / "check-passed.json"
        record.parent.mkdir(exist_ok=True)
        record.write_text(json.dumps({"tree": self.git("rev-parse", "HEAD^{tree}"), "target": "test"}))

    def run_script(self, mode, stdin):
        return subprocess.run(["python3", str(self.root / "tools" / "verify_local_check.py"), mode],
                              cwd=self.root, input=stdin, capture_output=True, text=True)

    def push(self, commit):
        return self.run_script("pre-push", f"refs/heads/main {commit} refs/heads/main {ZERO}\n").returncode

    def agent(self, command):
        return self.run_script("agent-hook", json.dumps({"tool_name": "Bash", "tool_input": {"command": command}})).returncode


class PrePush(LocalCheck):
    def test_refuses_when_nothing_has_passed(self):
        self.assertEqual(self.push(self.git("rev-parse", "HEAD")), 1)

    def test_accepts_the_tree_that_passed(self):
        self.record_pass()
        self.assertEqual(self.push(self.git("rev-parse", "HEAD")), 0)

    def test_accepts_the_same_tree_under_another_commit(self):
        self.record_pass()
        self.git("commit", "-q", "--amend", "-m", "reworded")
        self.assertEqual(self.push(self.git("rev-parse", "HEAD")), 0)

    def test_accepts_a_change_to_markdown_alone(self):
        self.record_pass()
        self.write("README.md", "changed\n")
        self.assertEqual(self.push(self.commit("docs")), 0)

    def test_refuses_a_change_to_the_changelog(self):
        self.record_pass()
        self.write("CHANGELOG.md", "# Changelog\n\n## Unreleased\n")
        self.assertEqual(self.push(self.commit("changelog")), 1)

    def test_refuses_a_change_to_code(self):
        self.record_pass()
        self.write("app.roc", "changed\n")
        self.assertEqual(self.push(self.commit("code")), 1)

    def test_ignores_a_branch_deletion(self):
        result = self.run_script("pre-push", f"(delete) {ZERO} refs/heads/old {self.git('rev-parse', 'HEAD')}\n")
        self.assertEqual(result.returncode, 0)


class AgentHook(LocalCheck):
    def test_refuses_a_pull_request_for_an_unverified_head(self):
        self.assertEqual(self.agent("gh pr create --fill"), 2)

    def test_allows_a_pull_request_for_a_verified_head(self):
        self.record_pass()
        self.assertEqual(self.agent("gh pr create --fill"), 0)

    def test_refuses_a_push_without_the_hook_installed(self):
        self.assertEqual(self.agent("git push origin main"), 2)

    def test_allows_a_push_with_the_hook_installed(self):
        self.git("config", "core.hooksPath", ".githooks")
        self.assertEqual(self.agent("git push origin main"), 0)

    def test_refuses_skipping_the_hook(self):
        self.git("config", "core.hooksPath", ".githooks")
        for command in ("git push --no-verify origin main", "git -c core.hooksPath=/dev/null push origin main"):
            with self.subTest(command=command):
                self.assertEqual(self.agent(command), 2)

    def test_finds_the_commands_in_a_command_line(self):
        for command in ("cd /tmp && git push origin main", "X=1 git push", "git -C . push", "/usr/bin/git push",
                        "make; gh pr create --fill", "(gh pr create)"):
            with self.subTest(command=command):
                self.assertEqual(self.agent(command), 2)

    def test_allows_other_commands(self):
        for command in ("git status", "zig build test", "echo push", "echo gh pr create",
                        'git commit -m "Refuse to push; gh pr create"', "git log --grep push", "git stash push"):
            with self.subTest(command=command):
                self.assertEqual(self.agent(command), 0)


if __name__ == "__main__":
    unittest.main()
