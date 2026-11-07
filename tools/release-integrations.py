#!/usr/bin/env python3
"""Bundles each official integration for a release, after
tools/release-bundle.sh has bundled the platform into zig-out/release/.

    tools/release-integrations.py <release URL>

An integration's package names the platform by a relative path in the
repository; its bundle names the platform's bundle by URL instead,
`<release URL>/<platform bundle>`, where the release URL is the directory
every bundle of the release is served from (on GitHub,
https://github.com/<owner>/<repo>/releases/download/v<version>). Each
bundle lands beside the platform's in zig-out/release/, with:

- release.json: the version, file, URL, and SHA-256 of every bundle, and
  the platform versions each integration declares (the published
  compatibility manifest records the SHA-256, docs/design/integration-releases.md)
- release-notes.md: the release notes: the version's section of
  CHANGELOG.md (tools/release_version.py), and the URLs to put in an app
"""
import functools
import hashlib
import http.server
import json
import os
import re
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

import release_version

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "zig-out/release"
LOCAL_PLATFORM = 'pf: platform "../../../platform/main.roc"'


def fail(message):
    print(f"release-integrations: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bundle(directory, output, roc, environment):
    """Bundles the package in `directory`; returns the new file's name and
    its size uncompressed."""
    before = {path.name for path in output.glob("*.tar.zst")}
    result = subprocess.run([roc, "bundle", "main.roc", "--output-dir", str(output)], cwd=directory,
                            env=environment, capture_output=True, text=True)
    if result.returncode != 0:
        fail(f"roc bundle failed in {directory}:\n{result.stdout}{result.stderr}")
    created = {path.name for path in output.glob("*.tar.zst")} - before
    if len(created) != 1:
        fail(f"roc bundle made {sorted(created)} in {directory}")
    size = re.search(r"Uncompressed size: (\d+) bytes", result.stdout)
    if not size:
        fail(f"roc bundle did not report the size:\n{result.stdout}")
    return created.pop(), int(size.group(1))


class BundleServer(http.server.ThreadingHTTPServer):
    """Serves the platform's bundle on 127.0.0.1. It skips HTTPServer's
    lookup of the host's name (`socket.getfqdn`), which can stall on a CI
    runner's resolver."""

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "127.0.0.1", self.server_address[1]


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass


def warm_cache(staging, platform, roc):
    """An environment whose Roc cache holds the platform's bundle."""
    environment = {**os.environ, "ROC_CACHE_DIR": str(staging / "roc-cache"), "XDG_CACHE_HOME": str(staging / "xdg-cache")}
    handler = functools.partial(QuietHandler, directory=str(platform.parent))
    with BundleServer(("127.0.0.1", 0), handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            port = server.server_address[1]
            warm = staging / "warm"
            warm.mkdir()
            (warm / "main.roc").write_text(f'package [] {{ pf: platform "http://127.0.0.1:{port}/{platform.name}" }}\n')
            result = subprocess.run([roc, "check", "main.roc"], cwd=warm, env=environment, capture_output=True, text=True)
            if result.returncode != 0:
                fail(f"Roc could not fetch the platform's bundle:\n{result.stdout}{result.stderr}")
        finally:
            server.shutdown()
            thread.join()
    return environment


def main():
    if len(sys.argv) != 2:
        fail("usage: tools/release-integrations.py <release URL>")
    release_url = sys.argv[1].rstrip("/")
    roc = shutil.which("roc") or fail("roc is not on PATH")
    manifest = json.loads((ROOT / "integrations/compatibility.json").read_text())
    platforms = sorted(OUTPUT.glob("*.tar.zst"))
    if len(platforms) != 1:
        fail(f"expected the platform's bundle alone in {OUTPUT}, found {[path.name for path in platforms]}")
    platform = platforms[0]
    platform_url = f"{release_url}/{platform.name}"

    integrations = []
    with tempfile.TemporaryDirectory() as staging:
        # `roc bundle` fetches the platform the package names, and the
        # release URL is not served before the release is published. Roc
        # keeps a fetched package by its hash, which the bundle's name is,
        # so a cache of our own gets the platform from a local server first.
        environment = warm_cache(Path(staging), platform, roc)
        for integration in manifest["integrations"]:
            package_root = ROOT / integration["package_root"]
            # Only the official integrations under integrations/ are released.
            if not package_root.is_relative_to(ROOT / "integrations"):
                continue
            name = integration["name"]
            directory = Path(staging) / name
            shutil.copytree(package_root.parent, directory, ignore=shutil.ignore_patterns("*.md"))
            main_file = directory / "main.roc"
            text = main_file.read_text()
            if text.count(LOCAL_PLATFORM) != 1:
                fail(f"{name}: its package header does not name the platform as {LOCAL_PLATFORM}")
            main_file.write_text(text.replace(LOCAL_PLATFORM, f'pf: platform "{platform_url}"'))
            file_name, size = bundle(directory, OUTPUT, roc, environment)
            if size > integration["max_unpacked_bytes"]:
                fail(f"{name}: the bundle is {size} bytes uncompressed, over {integration['max_unpacked_bytes']}")
            integrations.append({
                "name": name,
                "version": integration["version"],
                "platform_versions": integration["platform_versions"],
                "file": file_name,
                "url": f"{release_url}/{file_name}",
                "sha256": sha256(OUTPUT / file_name),
                "unpacked_bytes": size,
            })

    version = manifest["core"]["version"]
    release = {
        "version": version,
        "platform": {"file": platform.name, "url": platform_url, "sha256": sha256(platform)},
        "integrations": integrations,
    }
    (OUTPUT / "release.json").write_text(json.dumps(release, indent=2) + "\n")
    rows = "\n".join(
        f"| `{item['name']}` | {item['version']} | {item['platform_versions']} | `{item['url']}` |" for item in integrations
    )
    try:
        changes = release_version.notes(version)
    except release_version.Invalid as error:
        fail(str(error))
    (OUTPUT / "release-notes.md").write_text(f"""{changes}

### Using this release

```roc
app [program] {{
	pf: platform "{platform_url}",
}}
```

| Integration | Version | Platform versions | URL |
|---|---|---|---|
{rows}
""")
    for item in integrations:
        print(f"{item['name']} {item['version']}: {item['file']} ({item['unpacked_bytes']} bytes)")


if __name__ == "__main__":
    main()
