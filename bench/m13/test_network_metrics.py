"""ENA availability and cumulative-counter boundaries."""
import copy
import unittest
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch

import network_metrics


class NetworkMetricsTests(unittest.TestCase):
    def test_all_allowance_counters_required(self):
        lines = [f'{name}: 0' for name in network_metrics.REQUIRED]
        self.assertEqual(len(network_metrics.parse_ena('\n'.join(lines))), 5)
        for index in range(len(lines)):
            with self.subTest(missing=lines[index]), self.assertRaises(ValueError):
                network_metrics.parse_ena('\n'.join(lines[:index] + lines[index + 1:]))

    def test_counter_delta_boundary(self):
        before = {'valid': True, 'interfaces': {'eth0': {'counters': dict.fromkeys(network_metrics.REQUIRED, 1)}}}
        for end in (0, 1, 2):
            after = copy.deepcopy(before)
            after['interfaces']['eth0']['counters']['pps_allowance_exceeded'] = end
            if end == 0:
                with self.assertRaises(ValueError):
                    network_metrics.changes(before, after)
            else:
                self.assertEqual(network_metrics.changes(before, after)['eth0']['pps_allowance_exceeded'], end - 1)

    def test_unavailable_is_not_zero_events(self):
        for invalid in ({'valid': False}, {'valid': True, 'interfaces': {}}):
            with self.assertRaises(ValueError):
                network_metrics.changes(invalid, invalid)

    def test_failed_collection_retains_diagnostic_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'eth0').mkdir()
            response = subprocess.CompletedProcess([], 1, stdout='partial', stderr='unsupported')
            with patch.object(network_metrics.subprocess, 'run', return_value=response):
                result = network_metrics.snapshot(root)
            self.assertFalse(result['valid'])
            self.assertEqual(result['interfaces']['eth0']['stderr'], 'unsupported')
            self.assertEqual(result['interfaces']['eth0']['stdout'], 'partial')


if __name__ == '__main__':
    unittest.main()
