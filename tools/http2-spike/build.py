#!/usr/bin/env python3
"""Build the isolated HTTP/2 spike with the repository's pinned Zig compiler."""
import argparse
import hashlib
from pathlib import Path
import re
import subprocess
import shutil
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
VERSION = '1.71.0'
SHA256 = 'c0f55121d88650e4b9227aec28cebaf664d2417ca60fe70be0f8d38829f52116'
URL = f'https://github.com/nghttp2/nghttp2/releases/download/v{VERSION}/nghttp2-{VERSION}.tar.xz'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', help='Zig target triple; omit to execute natively')
    args = parser.parse_args()
    if subprocess.check_output(['zig', 'version'], text=True).strip() != '0.17.1':
        raise SystemExit('use pinned Zig 0.17.1')
    out = ROOT / 'zig-out/http2-spike'
    out.mkdir(parents=True, exist_ok=True)
    archive = out / f'nghttp2-{VERSION}.tar.xz'
    if not archive.exists():
        archive.write_bytes(urllib.request.urlopen(URL, timeout=60).read())
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise SystemExit('nghttp2 archive digest mismatch')
    source = out / f'nghttp2-{VERSION}'
    if not source.exists():
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                if not (out / member.name).resolve().is_relative_to(out.resolve()):
                    raise SystemExit('unexpected archive path')
                if not (member.isfile() or member.isdir()):
                    raise SystemExit('unexpected archive link')
            tar.extractall(out)
    lib = source / 'lib'
    include = lib / 'includes'
    template = (include / 'nghttp2/nghttp2ver.h.in').read_text()
    (include / 'nghttp2/nghttp2ver.h').write_text(
        template.replace('@PACKAGE_VERSION@', VERSION).replace('@PACKAGE_VERSION_NUM@', '0x014700'))
    # The release's authoritative library source list excludes applications/TLS.
    listing = re.search(r'set\(NGHTTP2_SOURCES\s+(.*?)\)', (lib / 'CMakeLists.txt').read_text(), re.S).group(1)
    sources = [str(lib / name) for name in listing.split()]
    # One module owns the snapshot, including imports shared by net and fiber.
    if (out / 'host').exists():
        shutil.rmtree(out / 'host')
    shutil.copytree(ROOT / 'platform/host', out / 'host')
    shutil.copyfile(ROOT / 'tools/http2-spike/server.zig', out / 'server.zig')
    target = args.target or 'native'
    executable = out / f'server-{target}'
    header = out / 'bindings.h'
    header.write_text('#define NGHTTP2_STATICLIB 1\n#include <nghttp2/nghttp2.h>\n'
                      '#include <stdlib.h>\n#include <unistd.h>\n#include <signal.h>\n')
    translate = ['zig', 'translate-c', '-lc', '-I', str(include)]
    if args.target:
        translate += ['-target', args.target]
    with (out / 'c.zig').open('w') as bindings:
        subprocess.run([*translate, str(header)], stdout=bindings, check=True)
    command = ['zig', 'build-exe', '-O', 'ReleaseSafe', '-lc', '-I', str(include),
               '-cflags', '-std=c11', '-DNGHTTP2_STATICLIB', '-DBUILDING_NGHTTP2',
               '-DHAVE_ARPA_INET_H=1', '-DHAVE_NETINET_IN_H=1',
               '-DHAVE_CLOCK_GETTIME=1', '-DHAVE_DECL_CLOCK_MONOTONIC=1',
               '-D_POSIX_C_SOURCE=200809L', '--', *sources]
    if args.target:
        command += ['-target', args.target]
    command += [f'-Mroot={out / "server.zig"}', f'-femit-bin={executable}']
    subprocess.run(command, cwd=ROOT, check=True)
    print(executable)


if __name__ == '__main__':
    main()
