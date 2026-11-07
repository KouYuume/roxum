#!/usr/bin/env python3
"""A compatibility digest records that an integration was checked, so nothing
may be listed that the release gate does not run: every package under
integrations/ is in the manifest, and every application of the manifest is built
and run by a test in tools/check.py."""
import importlib.util
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def tests():
    spec = importlib.util.spec_from_file_location("check", ROOT / "tools" / "check.py")
    check = importlib.util.module_from_spec(spec)
    sys.modules["check"] = check
    spec.loader.exec_module(check)
    return check.TESTS


def main():
    manifest = json.loads((ROOT / "integrations" / "compatibility.json").read_text())
    problems = []

    listed = {integration["package_root"] for integration in manifest["integrations"]}
    for package in sorted((ROOT / "integrations").glob("*/package/main.roc")):
        name = package.relative_to(ROOT).as_posix()
        if name not in listed:
            problems.append(f"{name} is not in the manifest")

    run = set()
    for test in tests():
        # A `Command` builds nothing of its own.
        run.update(getattr(test, "apps", {}).values())
    for integration in manifest["integrations"]:
        for application in integration["applications"]:
            if application not in run:
                problems.append(f"{integration['name']}: no test in tools/check.py runs {application}")

    if problems:
        for problem in problems:
            print(problem, file=sys.stderr)
        raise SystemExit(1)
    print(f"{len(manifest['integrations'])} integrations are listed, and a test runs each application")


if __name__ == "__main__":
    main()
