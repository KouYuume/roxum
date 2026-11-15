"""Published Protobuf entries must describe the actual colocated artifacts."""
import hashlib
import json
from pathlib import Path

output = Path('zig-out/release')
release = json.loads((output / 'release.json').read_text())
protobuf = json.loads((output / 'protobuf.json').read_text())
assert release['protobuf'] == protobuf
assert protobuf['version'] == protobuf['generator_version']
assert protobuf['roc_revision'] == Path('.roc-revision').read_text().strip()
for kind in ('wire', 'source'):
    item = protobuf[kind]
    artifact = output / item['file']
    assert item['url'].endswith('/' + item['file'])
    assert hashlib.sha256(artifact.read_bytes()).hexdigest() == item['sha256']
assert protobuf['wire']['unpacked_bytes'] <= protobuf['max_unpacked_bytes']
notes = (output / 'release-notes.md').read_text()
assert protobuf['wire']['url'] in notes and protobuf['source']['url'] in notes
print('PASS Protobuf release metadata and artifact hashes')
