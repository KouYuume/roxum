"""Build independently usable Protobuf artifacts; never publish them."""
import argparse
import gzip
import hashlib
import io
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("release_integrations", ROOT / "tools/release-integrations.py")
release_helpers = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(release_helpers)
bundle = release_helpers.bundle
MANIFEST = Path('libraries/roc-protobuf/compatibility.json')
TOOL = Path('tools/protoc-gen-roc')


def compatibility(root=ROOT):
    value = json.loads((root / MANIFEST).read_text())
    if value.get('schema_version') != 1:
        raise ValueError('unsupported Protobuf compatibility schema')
    if not re.fullmatch(r'\d+\.\d+\.\d+', value['version']):
        raise ValueError('invalid Protobuf version')
    if not re.fullmatch(r'[0-9a-f]{40}', value['roc_revision']) or value['roc_revision'] != (root / '.roc-revision').read_text().strip():
        raise ValueError('Protobuf compiler compatibility is stale')
    if not re.fullmatch(r'[0-9A-Za-z._-]+', value.get('roc_release', '')):
        raise ValueError('invalid Roc release name')
    if value['generator_version'] != value['version']:
        raise ValueError('generator and wire package must use the same version')
    if value['schema_subset'] != 'proto3-v1':
        raise ValueError('unsupported Protobuf schema contract')
    if type(value['max_unpacked_bytes']) is not int or value['max_unpacked_bytes'] <= 0:
        raise ValueError('invalid Protobuf unpacked size limit')
    return value


def source_files(root=ROOT):
    # Ship source and pinned dependency installation instructions, never installed
    # Python/native tools, caches, host archives, or platform modules.
    files = [Path('LICENSE'), Path('.roc-revision'), MANIFEST,
             Path('libraries/roc-protobuf/DISTRIBUTION.md'),
             TOOL / 'requirements.txt', TOOL / 'protoc-gen-roc']
    files += [p.relative_to(root) for p in (root / TOOL).glob('*.py')]
    files += [p.relative_to(root) for p in (root / 'libraries/roc-protobuf/package').glob('*.roc')]
    return sorted(files)


def source_archive(path, root=ROOT):
    # Stable timestamps, modes and gzip headers make identical source archives
    # byte-identical regardless of checkout mtime, user, or output directory.
    with path.open('wb') as raw:
        with gzip.GzipFile(filename='', fileobj=raw, mode='wb', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w', format=tarfile.USTAR_FORMAT) as archive:
                for relative in source_files(root):
                    data = (root / relative).read_bytes()
                    entry = tarfile.TarInfo(relative.as_posix())
                    entry.size = len(data)
                    entry.mode = 0o755 if relative.name == 'protoc-gen-roc' else 0o644
                    archive.addfile(entry, io.BytesIO(data))


def build(output, release_url, root=ROOT):
    contract = compatibility(root)
    roc = os.environ.get('ROC_BIN', 'roc')
    version = subprocess.check_output([roc, 'version'], text=True).strip()
    if version != f"Roc compiler version {contract['roc_release']}":
        raise ValueError('Roc compiler does not match Protobuf compatibility revision')
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temporary:
        staging = Path(temporary)
        package = staging / 'package'
        shutil.copytree(root / 'libraries/roc-protobuf/package', package)
        shutil.copyfile(root / 'LICENSE', package / 'LICENSE')
        # Bundle in an empty directory so repeated release builds are valid.
        assets = staging / 'assets'
        assets.mkdir()
        file, size = bundle(package, assets, roc, os.environ.copy(), ("LICENSE",))
        if size > contract['max_unpacked_bytes']:
            raise ValueError('Protobuf package exceeds unpacked size limit')
        archive = assets / f"roc-protobuf-{contract['version']}-source.tar.gz"
        source_archive(archive, root)
        items = {}
        for kind, source in [('wire', assets / file), ('source', archive)]:
            shutil.copyfile(source, output / source.name)
            items[kind] = {'file': source.name, 'url': release_url.rstrip('/') + '/' + source.name,
                           'sha256': hashlib.sha256(source.read_bytes()).hexdigest()}
        items['wire']['unpacked_bytes'] = size
    result = {**contract, **items}
    (output / 'protobuf.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'zig-out/protobuf-release')
    parser.add_argument('--release-url', default='https://example.invalid/unpublished')
    args = parser.parse_args()
    result = build(args.output, args.release_url)
    print(f"roc-protobuf {result['version']}: {result['wire']['file']}")


if __name__ == '__main__':
    main()
