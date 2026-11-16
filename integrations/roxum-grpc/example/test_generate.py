"""Schema evolution must converge without deleting handwritten or last-good output."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

EXAMPLE = Path(__file__).resolve().parent
ROOT = EXAMPLE.parents[2]


def main():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        for name in ('generate.py', 'service.proto'):
            shutil.copyfile(EXAMPLE / name, root / name)
        command = [sys.executable, str(root / 'generate.py'), '--tool-root', str(ROOT),
                   '--python-output', str(root / 'python')]
        def generate(*arguments):
            result = subprocess.run(command + list(arguments), capture_output=True, text=True)
            assert result.returncode == 0, result.stdout + result.stderr
        schema = root / 'service.proto'
        original = schema.read_text()
        generate()
        generated = root / 'generated'
        assert (generated / 'Greeting.roc').exists()
        # A valid rename changes the module set; regeneration must reach a checked state.
        schema.write_text(original.replace('Greeting', 'Request'))
        generate()
        assert not (generated / 'Greeting.roc').exists()
        assert (generated / 'Request.roc').exists()
        generate('--check')
        # Unrelated Roc files are not disposable just because they share the directory.
        note = generated / 'Handwritten.roc'
        note.write_text('Handwritten := {}\n')
        schema.write_text(original)
        generate()
        assert not (generated / 'Request.roc').exists()
        assert note.read_text() == 'Handwritten := {}\n'
        # Valid proto2 syntax is rejected by the plugin; no previous module may change.
        before = {p.name: p.read_bytes() for p in generated.iterdir()}
        schema.write_text(original.replace('"proto3"', '"proto2"').replace('string ', 'optional string '))
        failed = subprocess.run(command, capture_output=True, text=True)
        assert failed.returncode != 0 and 'proto3' in failed.stderr, failed.stdout + failed.stderr
        assert before == {p.name: p.read_bytes() for p in generated.iterdir()}
    print('PASS example regeneration: renamed modules, handwritten files and rejected schemas')


if __name__ == '__main__':
    main()
