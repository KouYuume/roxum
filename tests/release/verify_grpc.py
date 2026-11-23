"""Generate and run all four RPC forms outside the checkout using release artifacts."""
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import venv

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tests/support'))
from roxum_process import read_port, stop


def run(command, cwd, env=None):
    subprocess.run(list(map(str, command)), cwd=cwd, env=env, check=True)


def verify(url, http_log):
    with urllib.request.urlopen(url + '/release.json', timeout=30) as response:
        release = json.load(response)
    grpc = next(item for item in release['integrations'] if item['name'] == 'roxum-grpc')
    protobuf = release['protobuf']
    platform, wire = release['platform'], protobuf['wire']
    with tempfile.TemporaryDirectory(prefix='roxum-grpc-release-') as directory:
        root = Path(directory)
        tools = root / 'tools-source'
        tools.mkdir()
        with urllib.request.urlopen(protobuf['source']['url'], timeout=30) as response:
            source = response.read()
        assert hashlib.sha256(source).hexdigest() == protobuf['source']['sha256']
        with tarfile.open(fileobj=io.BytesIO(source), mode='r:gz') as archive:
            for member in archive.getmembers():
                path = Path(member.name)
                assert member.isfile() and not path.is_absolute() and '..' not in path.parts
                destination = tools / path
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(archive.extractfile(member).read())
                destination.chmod(member.mode)
        # Only the distributed tool sources are available to the plugin launcher.
        environment = {**os.environ, 'ROC_CACHE_DIR': str(root / 'tool-cache'),
                       'XDG_CACHE_HOME': str(root / 'tool-xdg')}
        run([sys.executable, tools / 'tools/protoc-gen-roc/setup.py'], tools, environment)
        example = root / 'example'
        example.mkdir()
        for name in ('app.roc', 'service.proto', 'generate.py', 'client.py', 'requirements.txt'):
            shutil.copyfile(ROOT / 'integrations/roxum-grpc/example' / name, example / name)
        app = example / 'app.roc'
        text = app.read_text()
        for old, new in (('../package/main.roc', grpc['url']),
                         ('../../../platform/main.roc', platform['url']),
                         ('../../../libraries/roc-protobuf/package/main.roc', wire['url'])):
            assert text.count('"' + old + '"') == 1
            text = text.replace('"' + old + '"', '"' + new + '"')
        app.write_text(text)
        python = root / 'venv/bin/python'
        venv.create(root / 'venv', with_pip=True)
        run([python, '-m', 'pip', 'install', '--disable-pip-version-check', '--require-hashes',
             '--only-binary=:all:', '-r', example / 'requirements.txt'], example)
        bindings = root / 'python'
        run([python, 'generate.py', '--tool-root', tools, '--wire', wire['url'],
             '--grpc', grpc['url'], '--platform', platform['url'], '--python-output', bindings], example, environment)
        # The example asks for two threads, which interpreter builds do not run
        # (platform/host/single_thread_runtime.zig).
        for backend in ('speed', 'dev'):
            before = http_log.read_text()
            environment = {**os.environ, 'ROC_CACHE_DIR': str(root / ('roc-' + backend)),
                           'XDG_CACHE_HOME': str(root / ('xdg-' + backend))}
            executable = example / ('server-' + backend)
            run([os.environ.get('ROC_BIN', 'roc'), 'build', '--opt=' + backend,
                 '--output=' + str(executable), app], example, environment)
            after = http_log.read_text()
            for artifact in (platform, grpc, wire):
                request = 'GET /' + artifact['file'] + ' '
                assert after.count(request) > before.count(request), ('bundle was not fetched', backend, artifact['file'])
            process = subprocess.Popen([str(executable)], cwd=example, stdout=subprocess.PIPE,
                                       text=True, start_new_session=True)
            try:
                port = read_port(process)
                run([python, 'client.py', f'127.0.0.1:{port}', '--bindings', bindings], example)
            finally:
                status = stop(process)
                process.stdout.close()
            assert status == 0
            print(f'PASS distributed gRPC (all four forms) {backend}: generated service, three URL packages, metadata and status')


if __name__ == '__main__':
    verify(sys.argv[1], Path(sys.argv[2]))
