"""Generate both implementations and detect drift in the committed Roc fixture."""
import os
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURE = ROOT / 'tests/grpc-streaming'
TOOLS = ROOT / 'zig-out/protobuf-codegen'
CLIENT = ROOT / 'zig-out/grpc-streaming'
CLIENT.mkdir(parents=True, exist_ok=True)


def main():
    with tempfile.TemporaryDirectory() as directory:
        output = pathlib.Path(directory)
        subprocess.run([str(TOOLS / 'bin/protoc'), '-I', str(FIXTURE),
                        '--plugin=protoc-gen-roc=' + str(ROOT / 'tools/protoc-gen-roc/protoc-gen-roc'),
                        '--roc_out=wire=../../../libraries/roc-protobuf/package/main.roc,grpc=../../../integrations/roxum-grpc/package/main.roc,pf=../../../platform/main.roc:' + directory,
                        '--python_out=' + str(CLIENT), str(FIXTURE / 'streaming.proto')], check=True)
        files = sorted(output.glob('*.roc'))
        subprocess.run([os.environ.get('ROC_BIN', 'roc'), 'fmt', *map(str, files)], check=True)
        if '--write' in sys.argv:
            for file in files:
                (FIXTURE / 'generated' / file.name).write_bytes(file.read_bytes())
        else:
            assert {f.name for f in files} == {f.name for f in (FIXTURE / 'generated').glob('*.roc')}
            for file in files:
                assert file.read_bytes() == (FIXTURE / 'generated' / file.name).read_bytes(), file.name + ': regenerate with --write'
    print('PASS reproducible streaming service generation')


if __name__ == '__main__':
    main()
