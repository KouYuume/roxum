"""Negative controls ensure the scalar fuzzer detects post-decode failures."""
import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
ROC = os.environ.get('ROC_BIN', 'roc')


class ScalarOracle(unittest.TestCase):
    def run_oracle(self, writer=None, opt="dev"):
        with tempfile.TemporaryDirectory(prefix='roxum-scalar-oracle-') as directory:
            base = pathlib.Path(directory)
            for name in ['ProtobufWire.roc', 'ProtobufScalar.roc']:
                (base / name).write_bytes((ROOT / 'libraries/roc-protobuf/package' / name).read_bytes())
            source = (ROOT / 'fuzz/roc-protobuf/ScalarFuzz.roc').read_text()
            if writer is not None:
                original = 'ProtobufScalar.write_uint32)'
                self.assertEqual(source.count(original), 1)
                source = source.replace(original, 'faulty_write)')
                source += '\nfaulty_write : ProtobufWire.Writer, U32 -> Try(ProtobufWire.Writer, ProtobufWire.Error)\n'
                source += writer + '\n'
            target = base / 'ScalarFuzz.roc'
            target.write_text(source)
            return subprocess.run([ROC, 'test', f'--opt={opt}', str(target)], cwd=ROOT, capture_output=True,
                                  text=True, timeout=60)

    def test_real_codecs_accept_valid_and_malformed_inputs(self):
        for opt in ['dev', 'interpreter']:
            with self.subTest(opt=opt):
                result = self.run_oracle(opt=opt)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('tests passed', result.stdout + result.stderr)

    def test_post_decode_failures_are_detected(self):
        cases = [
            ('encode rejection',
             'faulty_write = |_writer, _value| Err(OutputLimit)',
             'scalar encode unexpectedly failed'),
            ('malformed encoding',
             'faulty_write = |_writer, _value| Ok(ProtobufWire.Writer.{ bytes: [128], limit: 4106 })',
             'scalar encoding could not be decoded'),
            ('re-encode rejection',
             'faulty_write = |writer, value| if value == 0 { Err(OutputLimit) } else { ProtobufWire.write_varint(writer, 0) }',
             'scalar re-encode unexpectedly failed'),
        ]
        for name, writer, diagnostic in cases:
            with self.subTest(name=name):
                # The pinned Roc's native test crash path SIGSEGVs on Linux x64,
                # even for a standalone `expect { crash "probe" }`. Interpret
                # negative controls so only the intended oracle diagnostic passes.
                result = self.run_oracle(writer, opt='interpreter')
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('Roc application crashed with this message:', result.stdout + result.stderr)
                self.assertIn(diagnostic, result.stdout + result.stderr)
                self.assertIn('0 compiler errors', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
