"""Verify that slow tool preparation finishes before codec verification starts."""
import contextlib
import importlib.util
import io
import pathlib
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('roxum_check', ROOT / 'tools/check.py')
check = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = check
spec.loader.exec_module(check)


class Schedule(unittest.TestCase):
    def test_verification_waits_for_preparation(self):
        prepared = threading.Event()
        builds_finished = threading.Event()
        verification_started = threading.Event()
        observed = []

        def run_job(name, *args, **kwargs):
            if name.startswith('test-protobuf-codegen/checks-'):
                if not builds_finished.wait(5):
                    raise AssertionError('build phase never finished')
                # Let an incorrectly scheduled verifier expose the race. With
                # correct scheduling main is joining this preparation lane.
                verification_started.wait(0.1)
                prepared.set()
            return True

        def build_all(*args):
            builds_finished.set()
            return True

        def verify(*args):
            observed.append(prepared.is_set())
            verification_started.set()
            return True

        with tempfile.TemporaryDirectory() as directory, contextlib.ExitStack() as stack:
            for name, value in [('OUT', pathlib.Path(directory)), ('LOGS', pathlib.Path(directory) / 'logs'),
                                ('run_job', run_job), ('build_all', build_all), ('verify', verify),
                                ('install_host', lambda allocator: None), ('roc_target', lambda: 'arm64mac')]:
                stack.enter_context(patch.object(check, name, value))
            stack.enter_context(patch.object(sys, 'argv', ['check.py', '--only', 'test-protobuf-codegen']))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            check.main()
        self.assertEqual(observed, [True] * 6, 'verification ran before the private Python/bindings were ready')


if __name__ == '__main__':
    unittest.main()
