"""Toolchain identity and generator counter availability contracts."""
import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import client_metrics
import toolchain_lock


class PreflightTests(unittest.TestCase):
    def test_sample_window_is_in_the_client_clock_domain(self):
        # A counter snapshot takes time; retain both bounds rather than a point estimate.
        sampler = client_metrics.ClientSampler()
        sampler.started_ns = 100
        def collect():
            sampler.event.set()
            return {'stat': 'cpu 1 2 3'}
        with patch.object(client_metrics, 'snapshot', side_effect=collect), \
             patch.object(client_metrics.time, 'monotonic_ns', side_effect=[120, 140]):
            sampler._run()
        self.assertEqual(sampler.samples, [{'seconds': 20 / 1e9,
                         'begin_monotonic_ns': 120, 'end_monotonic_ns': 140,
                         'counters': {'stat': 'cpu 1 2 3'}}])

    def test_lock_matches_and_rejects_each_identity_change(self):
        expected = {'schema_version': 1, 'os': 'Linux', 'architecture': 'x86_64',
                    'versions': {'roc': 'v1', 'go': 'v2'}, 'environment': {'GOFLAGS': None}}
        toolchain_lock.verify(expected, copy.deepcopy(expected))
        # Architecture, compiler versions, flags, and schema are independent mismatch classes.
        for key, replacement in [('architecture', 'aarch64'), ('versions', {'roc': 'v2', 'go': 'v2'}),
                                 ('environment', {'GOFLAGS': '-race'}), ('schema_version', 2)]:
            actual = copy.deepcopy(expected)
            actual[key] = replacement
            with self.subTest(key=key), self.assertRaises(ValueError):
                toolchain_lock.verify(expected, actual)

    def test_counter_files_required(self):
        # All required counters present vs one missing: partial telemetry must not look complete.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            names = ('stat', 'loadavg', 'meminfo', 'net/dev', 'net/snmp', 'net/netstat')
            for name in names:
                target = root / name
                target.parent.mkdir(exist_ok=True)
                target.write_text('counter 1\n')
            self.assertEqual(set(client_metrics.snapshot(root)), set(names))
            (root / 'net/dev').unlink()
            with self.assertRaises(FileNotFoundError):
                client_metrics.snapshot(root)

    def test_two_samples_required_for_deltas(self):
        # 1/2/3 samples straddle the minimum for calculating a counter delta.
        for count in (1, 2, 3):
            sampler = client_metrics.ClientSampler()
            sampler.samples = [{}] * count
            with patch.object(sampler.thread, 'join'), patch.object(sampler.thread, 'is_alive', return_value=False):
                result = sampler.stop()
            self.assertEqual(result['valid'], count >= 2)
            self.assertFalse(result['headroom_verified'])


if __name__ == '__main__':
    unittest.main()
