"""Exercise distributed tooling and URL imports outside the repository checkout."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import protobuf_distribution as distribution
BundleServer = distribution.release_helpers.BundleServer
QuietHandler = distribution.release_helpers.QuietHandler


class Compatibility(unittest.TestCase):
    def test_contract_rejects_mismatches(self):
        original = distribution.compatibility()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / distribution.MANIFEST
            manifest.parent.mkdir(parents=True)
            (root / '.roc-revision').write_text(original['roc_revision'])
            for field, value in [('schema_version', 2), ('version', 'invalid'),
                                 ('generator_version', '0.2.0'), ('roc_revision', 'old'), ('roc_release', ''),
                                 ('schema_subset', 'proto2'), ('max_unpacked_bytes', 0),
                                 ('max_unpacked_bytes', -1), ('max_unpacked_bytes', True)]:
                manifest.write_text(json.dumps({**original, field: value}))
                with self.subTest(field=field), self.assertRaises(ValueError):
                    distribution.compatibility(root)


    def test_wrong_compiler_produces_no_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            compiler = root / 'roc'
            compiler.write_text('#!/bin/sh\necho "Roc compiler version wrong"\n')
            compiler.chmod(0o755)
            result = subprocess.run([sys.executable, ROOT / 'tools/protobuf_distribution.py',
                                     '--output', root / 'output'],
                                    env={**os.environ, 'ROC_BIN': str(compiler)},
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('compiler does not match', result.stderr)
            self.assertFalse((root / 'output').exists())


def run(command, cwd, env=None):
    subprocess.run(list(map(str, command)), cwd=cwd, env=env, check=True)


def verify():
    with tempfile.TemporaryDirectory(prefix='roxum-protobuf-package-') as directory:
        temporary = Path(directory)
        assets = temporary / 'assets'
        assets.mkdir()
        downloads = []
        class Handler(QuietHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=str(assets), **kwargs)

            def do_GET(self):
                downloads.append(self.path)
                super().do_GET()
        handler = Handler
        with BundleServer(('127.0.0.1', 0), handler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                url = f'http://127.0.0.1:{server.server_port}'
                manifest = distribution.build(assets, url)
                for kind in ('wire', 'source'):
                    artifact = assets / manifest[kind]['file']
                    assert hashlib.sha256(artifact.read_bytes()).hexdigest() == manifest[kind]['sha256']
                # The second build proves repeatability, including reruns into
                # an existing output directory rather than only a fresh staging dir.
                assert distribution.build(assets, url) == manifest
                extracted = temporary / 'extracted'
                extracted.mkdir()
                with tarfile.open(assets / manifest['source']['file']) as archive:
                    names = archive.getnames()
                    assert 'LICENSE' in names and '.roc-revision' in names
                    assert not any(name.startswith(('platform/', 'zig-out/')) for name in names)
                    assert set(names) == {p.as_posix() for p in distribution.source_files()}
                    for member in archive.getmembers():
                        assert member.isfile()
                        destination = extracted / member.name
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        destination.write_bytes(archive.extractfile(member).read())
                        destination.chmod(member.mode)
                # Expanded size uses actual bundled bytes: below/exact/above.
                contract_file = extracted / distribution.MANIFEST
                contract = json.loads(contract_file.read_text())
                size = manifest['wire']['unpacked_bytes']
                for limit in (size - 1, size, size + 1):
                    contract_file.write_text(json.dumps({**contract, 'max_unpacked_bytes': limit}))
                    if limit < size:
                        try:
                            distribution.build(temporary / 'bounded', url, extracted)
                        except ValueError as error:
                            assert 'size limit' in str(error)
                        else:
                            raise AssertionError('oversized package accepted')
                    else:
                        distribution.build(temporary / 'bounded', url, extracted)
                contract_file.write_text(json.dumps(contract))
                # Real installation from only shipped files, with a fresh tool
                # directory. The launcher must not reference the source checkout.
                run([sys.executable, 'tools/protoc-gen-roc/setup.py'], extracted)
                (extracted / 'sample.proto').write_text('''syntax = "proto3";
message Sample {
  uint32 value = 1;
  Sample next = 2;
  map<string, Sample> children = 3;
  oneof choice { string text = 4; Sample selected = 5; }
}
''')
                generated = extracted / 'generated'
                generated.mkdir()
                run(['zig-out/protobuf-codegen/bin/protoc', '-I.',
                     '--plugin=protoc-gen-roc=tools/protoc-gen-roc/protoc-gen-roc',
                     f"--roc_opt=wire={manifest['wire']['url']}", '--roc_out=generated', 'sample.proto'], extracted)
                (extracted / 'consumer.roc').write_text('''import generated.SampleRecursive
Consumer := [].{}
expect {
    limits = { input_bytes: 64, field_bytes: 64, depth: 4, tags: 16, entries: 8, materialized_bytes: 32 }
    SampleRecursive.Sample.(node) = SampleRecursive.Sample.decode([8, 7, 18, 2, 8, 9], limits)?
    child = match node.next {
        Absent => 0
        Present(box) => {
            SampleRecursive.Sample.(value) = Box.unbox(box)
            value.value
        }
    }
    encoded = SampleRecursive.Sample.encode(SampleRecursive.Sample.(node), 64)?
    node.value == 7 and child == 9 and encoded == [8, 7, 18, 2, 8, 9]
}
''')
                # A package header supplies the generated package dependency;
                # no platform declaration or roxum source is present.
                (extracted / 'main.roc').write_text('package [Consumer] { generated: "generated/main.roc" }\n')
                (extracted / 'consumer.roc').rename(extracted / 'Consumer.roc')
                environment = {**os.environ, 'ROC_CACHE_DIR': str(temporary / 'roc-cache'),
                               'XDG_CACHE_HOME': str(temporary / 'xdg-cache')}
                positive = subprocess.run([os.environ.get('ROC_BIN', 'roc'), 'test', 'main.roc'],
                                          cwd=extracted, env=environment, capture_output=True, text=True)
                positive_output = positive.stdout + positive.stderr
                assert positive.returncode == 0 and 'All (1) tests passed' in positive_output, positive_output
                assert '/' + manifest['wire']['file'] in downloads, downloads
                # A deliberately wrong consumer assertion must fail; importing
                # a package without executing its expectations is insufficient.
                consumer = extracted / 'Consumer.roc'
                consumer.write_text(consumer.read_text().replace('node.value == 7', 'node.value == 8'))
                negative = subprocess.run([os.environ.get('ROC_BIN', 'roc'), 'test', 'main.roc'],
                                          cwd=extracted, env=environment, capture_output=True, text=True)
                negative_output = negative.stdout + negative.stderr
                assert '1 failed' in negative_output and '0 compiler errors' in negative_output, negative_output
                print('PASS relocated generator, reproducible artifacts, URL wire package and recursive codec')
            finally:
                server.shutdown()
                thread.join()


if __name__ == '__main__':
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Compatibility)
    if not unittest.TextTestRunner().run(suite).wasSuccessful():
        sys.exit(1)
    verify()
