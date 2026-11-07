#!/usr/bin/env python3
import copy
import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
CHECKER = ROOT / "tools/check-integration-manifest.py"
BASE = json.loads((ROOT / "integrations/compatibility.json").read_text())


def expect_failure(name, mutate, expected):
    manifest = copy.deepcopy(BASE)
    mutate(manifest)
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json") as stream:
        json.dump(manifest, stream)
        stream.flush()
        result = subprocess.run(
            [sys.executable, str(CHECKER), "--manifest", stream.name],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
    if result.returncode == 0:
        raise RuntimeError(f"{name}: expected failure")
    if expected not in result.stderr:
        raise RuntimeError(f"{name}: missing {expected!r}: {result.stderr}")


def main():
    # An integration declares the platform versions it works with
    # (docs/design/versioning.md).
    expect_failure(
        "platform outside the declared versions",
        lambda data: data["integrations"][0].update(platform_versions="^0.2"),
        "does not declare platform",
    )
    expect_failure(
        "a platform with a new 0.MINOR, which is a breaking change",
        lambda data: data["core"].update(version="0.2.0"),
        "does not declare platform",
    )
    expect_failure(
        "platform below the declared versions",
        lambda data: data["core"].update(version="0.0.9"),
        "does not declare platform",
    )
    expect_failure(
        "a range not in caret form",
        lambda data: data["integrations"][0].update(platform_versions="0.1"),
        "invalid platform_versions",
    )
    expect_failure(
        "an integration version that is not semver",
        lambda data: data["integrations"][0].update(version="1"),
        "invalid version",
    )
    expect_failure(
        "old platform digest",
        lambda data: data["integrations"][0].update(requires_platform_sha256="0" * 64),
        "old platform digest",
    )
    expect_failure(
        "stale E2E compatibility lock",
        lambda data: data["integrations"][0].update(compatibility_sha256="0" * 64),
        "compatibility lock is stale",
    )
    expect_failure(
        "application platform mismatch",
        lambda data: data["integrations"][0].update(
            applications=["tests/platform-package/identity/mismatched-root.roc"]
        ),
        "application platform mismatch",
    )
    expect_failure(
        "expanded size limit",
        lambda data: data["integrations"][0].update(max_unpacked_bytes=1),
        "exceeds unpacked size limit",
    )
    print("M9P-3 manifest failure matrix: PASS")


if __name__ == "__main__":
    main()
