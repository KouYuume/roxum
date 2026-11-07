"""Write build provenance beside the binaries; missing metadata fails the build."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def output(argv):
    return subprocess.check_output(argv, cwd=ROOT, text=True).strip()


def record(directory, target, tools, images):
    sources = output(["git", "ls-files", "--cached", "--others", "--exclude-standard",
                      "--", "bench/m13", "platform", "libraries", "integrations",
                      "build.zig", "build.zig.zon", "tools", ".roc-revision"])
    candidates = {"linux": ("roxum",), "linux-deps": ("axum", "go")}
    binaries = candidates.get(target, ("roxum", "axum", "go"))
    manifest = {
        "schema_version": 1, "target": target, "host": platform.platform(),
        "architecture": platform.machine(),
        "revision": output(["git", "rev-parse", "HEAD"]),
        "working_tree": output(["git", "status", "--porcelain"]),
        "source_sha256": {name: sha256(ROOT / name) for name in sorted(set(sources.splitlines()))
                          if (ROOT / name).is_file()},
        "toolchains": {}, "images": images,
        "toolchain_lock": json.loads(Path(os.environ["BENCH_TOOLCHAIN_LOCK"]).read_text())
                          if target == "linux-native" else None,
        "environment": {key: os.environ.get(key) for key in
                        ("RUSTFLAGS", "RUSTUP_TOOLCHAIN", "GOFLAGS", "GOAMD64", "GOARM64",
                         "CC", "CFLAGS", "LDFLAGS", "CGO_ENABLED")},
        "binaries": {name: sha256(directory / name) for name in binaries},
    }
    for name, args in tools.items():
        executable = shutil.which(name)
        if executable is None:
            raise RuntimeError(f"missing compiler: {name}")
        manifest["toolchains"][name] = {"version": output([name, *args]),
                                      "executable_sha256": sha256(executable)}
    (directory / f"build-manifest-{target}.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("target", choices=["macos", "linux", "linux-deps", "linux-native"])
    parser.add_argument("--go-image")
    parser.add_argument("--rust-image")
    args = parser.parse_args()
    tools = {}
    if args.target != "linux-deps":
        tools.update(roc=["version"], zig=["version"])
    if args.target in ("macos", "linux-native"):
        tools.update(rustc=["-vV"], cargo=["--version"])
    if args.target == "linux-native":
        tools.update(go=["version"])
    images = {name: value for name, value in
              (("go", args.go_image), ("rust", args.rust_image)) if value}
    record(args.directory, args.target, tools, images)
