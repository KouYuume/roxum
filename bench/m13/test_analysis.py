"""Counter continuity boundaries and failed-experiment exclusion contracts."""
import copy
import unittest

import analyze_remote as analysis


def sample(time, busy, idle, guest=0):
    return {'seconds': time, 'counters': {
        'stat': f'cpu {busy} 0 0 {idle} 0 0 0 0 {guest} 0\ncpu0 {busy} 0 0 {idle} 0 0 0 0 {guest} 0\n',
        'net/dev': 'eth0: ' + ' '.join(str(busy) for _ in range(16)),
        'net/snmp': f'Tcp: RetransSegs\nTcp: {busy}\n'}}


class AnalysisTests(unittest.TestCase):
    def test_aa_requires_identical_binary_config_and_repetitions(self):
        row = {'server': 'a', 'scenario': 'plaintext', 'valid': True, 'rps': 100,
               'repetition': 0, 'start': {'binary': {'sha256': 'hash'}, 'config': {'cpus': '2-3'}}}
        control = copy.deepcopy(row)
        control.update(server='b', rps=110)
        data = {'comparison_valid': True, 'samples': [row, control]}
        self.assertAlmostEqual(analysis.aa_control(data, ['a', 'b'])['plaintext']['median_difference_percent'], 10)
        # Different binary, different budget, and missing paired repetition each invalidate A/A.
        for change in ('binary', 'config', 'repetition'):
            changed = copy.deepcopy(data)
            if change == 'repetition':
                changed['samples'][1]['repetition'] = 1
            else:
                changed['samples'][1]['start'][change] = {'sha256': 'other'} if change == 'binary' else {'cpus': '2'}
            with self.subTest(change=change), self.assertRaises(ValueError):
                analysis.aa_control(changed, ['a', 'b'])

    def test_counter_continuity_boundary(self):
        # A counter decrement is invalid; zero and one are the nearest valid deltas.
        for end in (9, 10, 11):
            if end < 10:
                with self.assertRaises(ValueError):
                    analysis.delta([10], [end])
            else:
                self.assertEqual(analysis.delta([10], [end]), [end - 10])

    def test_sample_count_boundary(self):
        for count in (1, 2, 3):
            metrics = {'valid': True, 'samples': [sample(n, n, n) for n in range(count)]}
            if count < 2:
                with self.assertRaises(ValueError):
                    analysis.telemetry(metrics)
            else:
                self.assertEqual(len(analysis.telemetry(metrics)['cpu_intervals']), count - 1)

    def test_guest_is_not_counted_twice_and_no_headroom_claim(self):
        result = analysis.telemetry({'valid': True, 'samples': [sample(0, 0, 0), sample(1, 10, 10, 10)]})
        self.assertEqual(result['cpu_intervals'][0]['cpu']['busy_percent'], 50)
        self.assertFalse(result['headroom_verified'])
        self.assertEqual(result['network_intervals'][0]['eth0']['rx_bps'], 80)

    def test_timestamp_must_increase(self):
        # Before, equal to, and after the prior timestamp.
        for end in (0, 1, 2):
            metrics = {'valid': True, 'samples': [sample(1, 0, 0), sample(end, 1, 1)]}
            if end <= 1:
                with self.assertRaises(ValueError):
                    analysis.telemetry(metrics)
            else:
                analysis.telemetry(metrics)

    def test_stolen_time_is_distinct_from_work(self):
        first, last = sample(0, 0, 0), sample(1, 20, 20)
        last['counters']['stat'] = 'cpu 20 0 0 20 0 0 0 60 0 0\ncpu0 20 0 0 20 0 0 0 60 0 0\n'
        result = analysis.telemetry({'valid': True, 'samples': [first, last]})
        self.assertEqual(result['cpu_intervals'][0]['cpu'], {'busy_percent': 20, 'steal_percent': 60})

    def test_failed_trial_excludes_whole_experiment_from_summary(self):
        row = {'server': 'a', 'scenario': 'plaintext', 'valid': True, 'rps': 100}
        data = {'kind': 'remote-diagnostic', 'comparison_valid': True, 'samples': [row]}
        self.assertTrue(analysis.summarize(data)['throughput'])
        failed = copy.deepcopy(row)
        failed['valid'] = False
        data['samples'].append(failed)
        self.assertFalse(analysis.summarize(data)['throughput'])
        self.assertEqual(len(analysis.summarize(data)['trials']), 2)


if __name__ == '__main__':
    unittest.main()
