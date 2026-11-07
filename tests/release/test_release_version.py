"""The rules tools/release_version.py applies to CHANGELOG.md and the versions."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
import release_version  # noqa: E402
from release_version import Invalid  # noqa: E402


def manifest(core="0.2.0", integration="0.1.0", package_root="integrations/roxum-cors/package/main.roc"):
    return {
        "core": {"version": core},
        "integrations": [{"name": "roxum-cors", "version": integration, "package_root": package_root}],
    }


RELEASED = """# Changelog

## Unreleased

## 0.2.0

### Breaking changes

- A change.

## 0.1.0

### Added

- The first release.
"""


class Sections(unittest.TestCase):
    def test_accepts_unreleased_then_releases_newest_first(self):
        titles = [title for title, _ in release_version.sections(RELEASED)]
        self.assertEqual(titles, ["Unreleased", "0.2.0", "0.1.0"])

    def test_rejects_a_file_without_the_title(self):
        with self.assertRaises(Invalid):
            release_version.sections("## 0.1.0\n")

    def test_rejects_a_section_title_that_is_not_a_version(self):
        for title in ("v0.1.0", "0.1", "0.1.0-dev", "Next"):
            with self.subTest(title=title), self.assertRaises(Invalid):
                release_version.sections(f"# Changelog\n\n## {title}\n")

    def test_rejects_an_entry_kind_outside_the_three(self):
        with self.assertRaises(Invalid):
            release_version.sections("# Changelog\n\n## 0.1.0\n\n### Changed\n\n- x\n")

    def test_rejects_releases_out_of_order(self):
        with self.assertRaises(Invalid):
            release_version.sections("# Changelog\n\n## 0.1.0\n\n## 0.2.0\n")

    def test_compares_versions_as_numbers(self):
        titles = release_version.sections("# Changelog\n\n## 0.10.0\n\n## 0.9.0\n")
        self.assertEqual([title for title, _ in titles], ["0.10.0", "0.9.0"])

    def test_rejects_unreleased_after_a_release(self):
        with self.assertRaises(Invalid):
            release_version.sections("# Changelog\n\n## 0.1.0\n\n## Unreleased\n")

    def test_rejects_a_repeated_section(self):
        with self.assertRaises(Invalid):
            release_version.sections("# Changelog\n\n## 0.1.0\n\n## 0.1.0\n")


class Notes(unittest.TestCase):
    def test_a_release_uses_its_own_section(self):
        self.assertEqual(release_version.notes("0.1.0", RELEASED), "### Added\n\n- The first release.")

    def test_a_prerelease_uses_unreleased(self):
        text = "# Changelog\n\n## Unreleased\n\n### Fixed\n\n- A fix.\n"
        self.assertEqual(release_version.notes("0.3.0-dev", text), "### Fixed\n\n- A fix.")

    def test_a_missing_section_fails(self):
        with self.assertRaises(Invalid):
            release_version.notes("0.3.0", RELEASED)


class ReleaseVersion(unittest.TestCase):
    def test_returns_the_core_version_when_everything_agrees(self):
        self.assertEqual(release_version.release_version(manifest(), RELEASED), "0.2.0")

    def test_rejects_a_prerelease_core_version(self):
        with self.assertRaises(Invalid):
            release_version.release_version(manifest(core="0.2.0-dev"), RELEASED)

    def test_rejects_a_version_that_is_not_the_newest_section(self):
        with self.assertRaises(Invalid):
            release_version.release_version(manifest(core="0.1.0"), RELEASED)

    def test_rejects_a_section_without_entries(self):
        text = "# Changelog\n\n## 0.2.0\n\n### Added\n"
        with self.assertRaises(Invalid):
            release_version.release_version(manifest(), text)

    def test_rejects_entries_left_in_unreleased(self):
        text = RELEASED.replace("## Unreleased\n", "## Unreleased\n\n### Fixed\n\n- Not moved.\n")
        with self.assertRaises(Invalid):
            release_version.release_version(manifest(), text)

    def test_rejects_a_prerelease_integration(self):
        with self.assertRaises(Invalid):
            release_version.release_version(manifest(integration="0.1.0-dev"), RELEASED)

    def test_ignores_integrations_that_are_not_released(self):
        test_only = manifest(integration="0.1.0-dev", package_root="tests/platform-package/integration/main.roc")
        self.assertEqual(release_version.release_version(test_only, RELEASED), "0.2.0")


if __name__ == "__main__":
    unittest.main()
