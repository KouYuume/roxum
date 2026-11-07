#!/usr/bin/env python3
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path


PLATFORM_DEPENDENCY = re.compile(r'\bpf\s*:\s*platform\s*"([^"]+)"')


VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-[0-9A-Za-z.-]+)?$")
CARET = re.compile(r"^\^(\d+)\.(\d+)$")


def parse_version(text, label):
    match = VERSION.match(text) if isinstance(text, str) else None
    if not match:
        fail(f"invalid version for {label}: {text!r}")
    return tuple(int(part) for part in match.groups()[:3])


def caret_bounds(text, label):
    """A Cargo caret range of a major and minor version (docs/design/versioning.md):
    `^0.1` is 0.1.0 up to, not including, 0.2.0; `^1.2` is 1.2.0 up to 2.0.0.
    A pre-release such as 0.1.0-dev is within the range of its version."""
    match = CARET.match(text) if isinstance(text, str) else None
    if not match:
        fail(f"invalid platform_versions for {label}: {text!r} (expected ^MAJOR.MINOR)")
    major, minor = int(match.group(1)), int(match.group(2))
    upper = (0, minor + 1, 0) if major == 0 else (major + 1, 0, 0)
    return (major, minor, 0), upper


def fail(message):
    raise ValueError(message)


def files_for_globs(root, patterns):
    files = set()
    for pattern in patterns:
        files.update(path for path in root.glob(pattern) if path.is_file())
    if not files:
        fail("platform source globs matched no files")
    return sorted(files)


def package_files(package_root):
    return sorted(
        path
        for path in package_root.parent.rglob("*")
        if path.is_file() and "__pycache__" not in path.parts
    )


def digest_files(root, paths, prefix=None):
    digest = hashlib.sha256()
    if prefix is not None:
        digest.update(prefix.encode())
        digest.update(b"\0")
    for path in sorted(set(paths)):
        try:
            name = path.relative_to(root).as_posix()
        except ValueError:
            fail(f"compatibility input is outside repository: {path}")
        digest.update(name.encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def platform_spec(header):
    match = PLATFORM_DEPENDENCY.search(header.read_text())
    if match is None:
        fail(f"platform dependency missing: {header}")
    return match.group(1)


def local_platform_identity(header, spec):
    if "://" in spec:
        return spec
    return str((header.parent / spec).resolve())


def validate_hex_digest(value, label):
    if re.fullmatch(r"[0-9a-f]{64}", value) is None:
        fail(f"{label} must be a lowercase SHA-256 digest")


def computed_values(root, manifest):
    core = manifest["core"]
    platform_files = files_for_globs(root, core["source_globs"])
    source_sha256 = digest_files(root, platform_files)
    integrations = {}
    for integration in manifest["integrations"]:
        package_root = root / integration["package_root"]
        inputs = package_files(package_root)
        inputs.extend(root / name for name in integration["applications"])
        inputs.extend(root / name for name in integration["compatibility_files"])
        integrations[integration["name"]] = {
            "compatibility_sha256": digest_files(
                root,
                inputs,
                prefix=source_sha256,
            ),
            "unpacked_bytes": sum(path.stat().st_size for path in package_files(package_root)),
        }
    return {
        "source_sha256": source_sha256,
        "integrations": integrations,
    }


def refresh(manifest, computed):
    core = manifest["core"]
    core["source_sha256"] = computed["source_sha256"]
    if core["artifact"]["kind"] == "local":
        core["artifact"]["content_sha256"] = computed["source_sha256"]
    # `platform_versions` is a decision about compatibility, not a lock, so a
    # refresh leaves it; the digests record the platform the checks ran on.
    for integration in manifest["integrations"]:
        integration["requires_platform_sha256"] = computed["source_sha256"]
        integration["compatibility_sha256"] = computed["integrations"][integration["name"]]["compatibility_sha256"]


def validate(root, manifest, computed):
    if manifest.get("schema_version") != 2:
        fail("unsupported integration manifest schema")
    core = manifest["core"]
    core_version = parse_version(core["version"], "core")
    platform_root = (root / core["platform_root"]).resolve()
    if not platform_root.is_file():
        fail("core platform root does not exist")
    validate_hex_digest(core["source_sha256"], "core source_sha256")
    if core["source_sha256"] != computed["source_sha256"]:
        fail("core platform source digest is stale")

    artifact = core["artifact"]
    validate_hex_digest(artifact["content_sha256"], "artifact content_sha256")
    if artifact["kind"] == "local":
        if (root / artifact["location"]).resolve() != platform_root:
            fail("local artifact does not select the core platform root")
        if artifact["content_sha256"] != core["source_sha256"]:
            fail("local artifact content hash differs from the platform source hash")
        expected_identity = str(platform_root)
    elif artifact["kind"] == "url":
        if not artifact["location"].startswith("https://"):
            fail("release artifact URL must use HTTPS")
        expected_identity = artifact["location"]
    else:
        fail("artifact kind must be local or url")

    names = set()
    for integration in manifest["integrations"]:
        name = integration["name"]
        if name in names:
            fail(f"duplicate integration name: {name}")
        names.add(name)
        parse_version(integration["version"], name)
        lower, upper = caret_bounds(integration["platform_versions"], name)
        if not lower <= core_version < upper:
            fail(
                f"integration does not declare platform {core['version']}: {name} "
                f"(platform_versions {integration['platform_versions']}); check it with this platform, then widen "
                f"the range and give the integration a new version if it changed"
            )
        validate_hex_digest(
            integration["requires_platform_sha256"],
            f"integration platform digest for {name}",
        )
        if integration["requires_platform_sha256"] != core["source_sha256"]:
            fail(f"integration targets an old platform digest: {name}")

        package_root = root / integration["package_root"]
        package_identity = local_platform_identity(package_root, platform_spec(package_root))
        if package_identity != expected_identity:
            fail(f"integration platform mismatch: {name}")
        for application_name in integration["applications"]:
            application = root / application_name
            app_identity = local_platform_identity(application, platform_spec(application))
            if app_identity != expected_identity:
                fail(f"application platform mismatch: {application_name}")

        observed = computed["integrations"][name]
        validate_hex_digest(
            integration["compatibility_sha256"],
            f"compatibility digest for {name}",
        )
        if integration["compatibility_sha256"] != observed["compatibility_sha256"]:
            fail(f"integration compatibility lock is stale: {name}")
        if observed["unpacked_bytes"] > integration["max_unpacked_bytes"]:
            fail(
                f"integration package exceeds unpacked size limit: {name} "
                f"({observed['unpacked_bytes']} > {integration['max_unpacked_bytes']})"
            )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path("integrations/compatibility.json"),
    )
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    manifest_path = args.manifest if args.manifest.is_absolute() else root / args.manifest
    try:
        manifest = json.loads(manifest_path.read_text())
        computed = computed_values(root, manifest)
        if args.refresh:
            refresh(manifest, computed)
        validate(root, manifest, computed)
    # A missing file is reported like any other invalid entry, not as a
    # traceback. JSON errors are ValueErrors.
    except (KeyError, TypeError, ValueError, OSError) as error:
        print(f"integration manifest invalid: {error}", file=sys.stderr)
        raise SystemExit(1)
    # Written only after the refreshed manifest validates, so a failed
    # refresh leaves the file as it was.
    if args.refresh:
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    for integration in manifest["integrations"]:
        observed = computed["integrations"][integration["name"]]
        print(
            f"{integration['name']}: compatible, "
            f"{observed['unpacked_bytes']} / {integration['max_unpacked_bytes']} bytes"
        )


if __name__ == "__main__":
    main()
