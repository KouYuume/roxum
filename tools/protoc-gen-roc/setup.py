"""Install pinned build-only tools; archives are verified before extraction."""
import hashlib
import io
import pathlib
import platform
import subprocess
import urllib.request
import venv
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEST = ROOT / 'zig-out/protobuf-codegen'
ARCHIVES = {
    ('Darwin', 'arm64'): ('osx-universal_binary', 'f998ba34b5a4e3c1d0657ad615f5e73e492eff2b186525303e84e6b6f7bbd2b1'),
    ('Darwin', 'x86_64'): ('osx-universal_binary', 'f998ba34b5a4e3c1d0657ad615f5e73e492eff2b186525303e84e6b6f7bbd2b1'),
    ('Linux', 'aarch64'): ('linux-aarch_64', '2b0fcf9b2c32cbadccc0eb7a88b841fffecd4a06fc80acdba2b5be45e815c38a'),
    ('Linux', 'x86_64'): ('linux-x86_64', '24e58fb231d50306ee28491f33a170301e99540f7e29ca461e0e80fd1239f8d1'),
}


def main():
    target, digest = ARCHIVES[(platform.system(), platform.machine())]
    DEST.mkdir(parents=True, exist_ok=True)
    archive = DEST / ('protoc-33.5-' + target + '.zip')
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        url = 'https://github.com/protocolbuffers/protobuf/releases/download/v33.5/' + archive.name
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != digest:
            raise RuntimeError('protoc archive hash mismatch')
        archive.write_bytes(data)
    with zipfile.ZipFile(io.BytesIO(archive.read_bytes())) as source:
        # Only the executable is needed: the pilot rejects imports.
        binary = DEST / 'bin/protoc'
        binary.parent.mkdir(exist_ok=True)
        binary.write_bytes(source.read('bin/protoc'))
        binary.chmod(0o755)
    python = DEST / 'venv/bin/python'
    if not python.exists():
        venv.create(DEST / 'venv', with_pip=True)
    subprocess.run([str(python), '-m', 'pip', 'install', '--disable-pip-version-check',
                    '--require-hashes', '--only-binary=:all:', '-r',
                    str(ROOT / 'tools/protoc-gen-roc/requirements.txt')], check=True)
    subprocess.run([str(binary), '--version'], check=True)


if __name__ == '__main__':
    main()
