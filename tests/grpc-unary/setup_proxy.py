"""Build a pinned nginx test proxy; no system installation or daemon changes."""
import hashlib
import io
import os
import pathlib
import platform
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEST = ROOT / 'zig-out/grpc-unary/proxy'
VERSION = '1.30.6'
# Official source: https://nginx.org/download/nginx-1.30.6.tar.gz
SHA256 = '3cf46f5ed7504d460125866b7bea99fb357f31d887e2e63b35503310e9b8b6c8'


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    archive = DEST / f'nginx-{VERSION}.tar.gz'
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        with urllib.request.urlopen('https://nginx.org/download/' + archive.name, timeout=60) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != SHA256:
            raise RuntimeError('nginx archive hash mismatch')
        archive.write_bytes(data)
    configure = ['./configure', '--with-http_ssl_module', '--with-http_v2_module',
                 '--without-http_rewrite_module', '--without-http_gzip_module',
                 '--prefix=' + str(DEST / 'unused-prefix')]
    if platform.system() == 'Darwin':
        prefix = subprocess.check_output(['brew', '--prefix', 'openssl@3'], text=True).strip()
        configure += ['--with-cc-opt=-I' + prefix + '/include', '--with-ld-opt=-L' + prefix + '/lib']
    fingerprint = hashlib.sha256((platform.platform() + repr(configure)).encode() + pathlib.Path(__file__).read_bytes()).hexdigest()
    marker = DEST / 'build-sha256'
    binary = DEST / 'nginx'
    if not binary.exists() or not marker.exists() or marker.read_text() != fingerprint:
        source = DEST / f'nginx-{VERSION}'
        if source.exists():
            shutil.rmtree(source)
        with tarfile.open(fileobj=io.BytesIO(archive.read_bytes()), mode='r:gz') as tar:
            # Reject links and paths outside the expected source root before extraction.
            for member in tar.getmembers():
                path = pathlib.PurePosixPath(member.name)
                if path.is_absolute() or '..' in path.parts or path.parts[0] != source.name or not (member.isfile() or member.isdir()):
                    raise RuntimeError('unexpected nginx archive entry')
            tar.extractall(DEST)
        subprocess.run(configure, cwd=source, check=True)
        subprocess.run(['make', '-j', str(min(os.cpu_count() or 1, 4))], cwd=source, check=True)
        shutil.copy2(source / 'objs/nginx', binary)
        marker.write_text(fingerprint)
    subprocess.run([str(binary), '-v'], check=True)


if __name__ == '__main__':
    main()
