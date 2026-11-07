#!/usr/bin/env python3
"""The version a release publishes, and its notes in CHANGELOG.md.

    python3 tools/release_version.py           print the version a release of
                                               this commit publishes; fail when
                                               the commit is not ready for one
    python3 tools/release_version.py --check   check CHANGELOG.md, and that it
                                               has a section for the current
                                               version

The core version in integrations/compatibility.json is the release's version
and tag (v<version>). CHANGELOG.md has a `## Unreleased` section for changes
not yet released and a `## <version>` section for each release, newest first.
A section's entries go under `### Breaking changes`, `### Added`, or
`### Fixed` (docs/design/versioning.md).
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHANGELOG = ROOT / "CHANGELOG.md"
MANIFEST = ROOT / "integrations/compatibility.json"

UNRELEASED = "Unreleased"
RELEASE = re.compile(r"^\d+\.\d+\.\d+$")
PRERELEASE = re.compile(r"^\d+\.\d+\.\d+-[0-9A-Za-z.-]+$")
KINDS = ("Breaking changes", "Added", "Fixed")


class Invalid(Exception):
    pass


def sections(text):
    """The `## ` sections of the changelog, in order, as (title, body) pairs."""
    lines = text.splitlines()
    if not lines or lines[0] != "# Changelog":
        raise Invalid("CHANGELOG.md must start with `# Changelog`")
    found = []
    for line in lines[1:]:
        if line.startswith("## "):
            found.append((line[3:].strip(), []))
        elif line.startswith("### "):
            if not found:
                raise Invalid(f"`{line}` comes before any `## ` section")
            if line[4:].strip() not in KINDS:
                raise Invalid(f"`{line}` in {found[-1][0]}: use one of " + ", ".join(f"`### {kind}`" for kind in KINDS))
            found[-1][1].append(line)
        elif line.startswith("#"):
            raise Invalid(f"unexpected heading `{line}`")
        elif found:
            found[-1][1].append(line)
    titles = [title for title, _ in found]
    for title in titles:
        if title != UNRELEASED and not RELEASE.match(title):
            raise Invalid(f"`## {title}`: a section is `## {UNRELEASED}` or `## MAJOR.MINOR.PATCH`")
    if len(set(titles)) != len(titles):
        raise Invalid("a section appears twice")
    if UNRELEASED in titles and titles[0] != UNRELEASED:
        raise Invalid(f"`## {UNRELEASED}` must be the first section")
    versions = [tuple(int(part) for part in title.split(".")) for title in titles if title != UNRELEASED]
    if versions != sorted(versions, reverse=True):
        raise Invalid("release sections must be newest first")
    return [(title, "\n".join(body).strip()) for title, body in found]


def has_entries(body):
    return any(line.startswith("- ") for line in body.splitlines())


def notes(version, text=None):
    """The changelog section for a version: its own section for a release,
    `## Unreleased` for a pre-release."""
    text = CHANGELOG.read_text() if text is None else text
    title = UNRELEASED if PRERELEASE.match(version) else version
    for found, body in sections(text):
        if found == title:
            return body
    raise Invalid(f"CHANGELOG.md has no `## {title}` section for version {version}")


def release_version(manifest, text):
    """The version to publish, after checking that everything says the same."""
    version = manifest["core"]["version"]
    if not RELEASE.match(version):
        raise Invalid(f"the core version {version} is not a release version (MAJOR.MINOR.PATCH)")
    found = sections(text)
    released = [(title, body) for title, body in found if title != UNRELEASED]
    if not released or released[0][0] != version:
        raise Invalid(f"the newest release section in CHANGELOG.md must be `## {version}`")
    if not has_entries(released[0][1]):
        raise Invalid(f"`## {version}` in CHANGELOG.md has no entries")
    for title, body in found:
        if title == UNRELEASED and has_entries(body):
            raise Invalid(f"`## {UNRELEASED}` still has entries; move them into `## {version}`")
    for integration in manifest["integrations"]:
        if not integration["package_root"].startswith("integrations/"):
            continue
        if not RELEASE.match(integration["version"]):
            raise Invalid(f"{integration['name']} {integration['version']} is not a release version")
    return version


def main():
    manifest = json.loads(MANIFEST.read_text())
    text = CHANGELOG.read_text()
    try:
        if sys.argv[1:] == ["--check"]:
            notes(manifest["core"]["version"], text)
            print(f"CHANGELOG.md has a section for {manifest['core']['version']}")
        elif sys.argv[1:] == []:
            print(release_version(manifest, text))
        else:
            sys.exit(__doc__)
    except Invalid as error:
        print(f"release version: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
