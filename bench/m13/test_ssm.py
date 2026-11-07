"""Exercise the SSM protocol locally; never invokes aws or contacts a host."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import ssm_control as ssm


class LocalTransport:
    def __init__(self, corrupt=False):
        self.calls = []
        self.corrupt = corrupt

    def script(self, source):
        self.calls.append(source)
        result = subprocess.check_output(['python3', '-c', source], text=True)
        if self.corrupt and 'base64.b64encode' in source:
            return result[:-5] + '\n'
        return result


class SSMTests(unittest.TestCase):
    def test_large_output_and_shell_metacharacters(self):
        # Larger than SSM's stdout limit; quotes and $ must remain literal in argv.
        with tempfile.TemporaryDirectory() as directory:
            controller = Path(directory) / "controller '$().py"
            controller.write_text("import json, random\nr=random.Random(42)\n"
                                  "print(json.dumps({'data': ''.join(chr(r.randrange(33,127)) for _ in range(100000))}))")
            transport = LocalTransport()
            result = ssm.transfer(transport, str(controller), 'snapshot')
            self.assertEqual(len(result['data']), 100000)
            self.assertGreater(sum('base64.b64encode' in call for call in transport.calls), 1)
            self.assertIn('unlink', transport.calls[-1])

    def test_truncated_output_rejected_and_cleaned(self):
        with tempfile.TemporaryDirectory() as directory:
            controller = Path(directory) / 'controller.py'
            controller.write_text("print('{}')")
            transport = LocalTransport(corrupt=True)
            with self.assertRaises(ValueError):
                ssm.transfer(transport, str(controller), 'snapshot')
            self.assertIn('unlink', transport.calls[-1])

    def test_eventual_consistency_and_pending(self):
        transport = ssm.SSM('benchmark', 'ap-northeast-1', 'i-0123456789abcdef0')
        with patch.object(transport, 'api', side_effect=[
            {'Command': {'CommandId': 'test'}}, RuntimeError('InvocationDoesNotExist'),
            {'Status': 'Pending'}, {'Status': 'Success', 'ResponseCode': 0, 'StandardOutputContent': '{}'}
        ]), patch.object(ssm.time, 'sleep'):
            self.assertEqual(transport.script('print(1)'), '{}')

    def test_terminal_failure_is_not_success(self):
        transport = ssm.SSM('benchmark', 'ap-northeast-1', 'i-0123456789abcdef0')
        for status in ['Failed', 'Cancelled', 'TimedOut']:
            with patch.object(transport, 'api', side_effect=[
                {'Command': {'CommandId': 'test'}}, {'Status': status, 'ResponseCode': 1}
            ]), self.assertRaises(RuntimeError):
                transport.script('print(1)')

    def test_scope_is_explicit_on_every_api_call(self):
        transport = ssm.SSM('benchmark', 'ap-northeast-1', 'i-0123456789abcdef0')
        with patch.object(ssm.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '{}', '')) as run:
            transport.api('get-command-invocation')
        self.assertEqual(run.call_args.args[0][:5], ['aws', '--profile', 'benchmark', '--region', 'ap-northeast-1'])


if __name__ == '__main__':
    unittest.main()
