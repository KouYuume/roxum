"""Resource boundaries and lifecycle failure handling without systemd or AWS."""
import copy
from pathlib import Path
import sys
import unittest
import subprocess
from argparse import Namespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import linux_server
import remote

BUDGET = {"cpus": "2-3", "memory_bytes": 1048576}
SNAPSHOT = {"InvocationID": "test-invocation", "ActiveState": "active", "cgroup": {
    "cpuset.cpus.effective": "2-3\n", "cpu.max": "200000 100000\n",
    "memory.max": "1048576\n", "memory.swap.max": "0\n",
    "memory.events": "low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\n"}}


class ResourceTests(unittest.TestCase):
    def test_control_bounds_include_transport_failures(self):
        # Successful output, nonzero exit, and timeout retain the same client clock bounds.
        for outcome in (subprocess.CompletedProcess(['control'], 0, '{}', ''),
                        subprocess.CompletedProcess(['control'], 1, '', 'failed'),
                        subprocess.TimeoutExpired(['control'], 300, output=b'partial')):
            records = []
            with patch.object(remote.time, 'monotonic_ns', side_effect=[100, 200]), \
                 patch.object(remote.subprocess, 'run') as run:
                if isinstance(outcome, Exception):
                    run.side_effect = outcome
                else:
                    run.return_value = outcome
                if isinstance(outcome, Exception) or outcome.returncode:
                    with self.assertRaises((RuntimeError, subprocess.TimeoutExpired)):
                        remote.control(['control'], records)
                else:
                    self.assertEqual(remote.control(['control'], records), {})
            self.assertEqual(records[0]['begin_monotonic_ns'], 100)
            self.assertEqual(records[0]['end_monotonic_ns'], 200)

    def test_interrupted_load_is_retained_and_server_stopped(self):
        config = {'host': '127.0.0.1', 'port': 8080, 'budget': BUDGET,
                  'snapshot': ['snapshot'], 'stop': ['stop']}
        with patch.object(remote, 'control', side_effect=[{}, SNAPSHOT, SNAPSHOT, {'stopped': True}]), \
             patch.object(remote.bench, 'validate_response'), \
             patch.object(remote.bench, 'run_oha', side_effect=[{'valid': True},
                 {'valid': False, 'interrupted': True, 'stdout': 'partial output'}]):
            row = remote.trial(config, {'start': ['start']}, remote.bench.SCENARIOS[0], 'oha', 1, 1)
        self.assertFalse(row['valid'])
        self.assertTrue(row['interrupted'])
        self.assertTrue(row['stop']['stopped'])
        self.assertEqual(row['stdout'], 'partial output')

    def test_frozen_rate_cannot_be_omitted_or_changed(self):
        plan = {'runs': 8, 'seconds': 30, 'warmup_seconds': 5,
                'scenarios': ['plaintext'], 'rate': 100}
        for rate in (None, 99, 100, 101):
            args = Namespace(runs=8, seconds=30, warmup_seconds=5, scenario=['plaintext'], rate=rate)
            if rate == 100:
                remote.check_measurement({'measurement': plan}, args)
            else:
                with self.assertRaises(ValueError):
                    remote.check_measurement({'measurement': plan}, args)

    def test_frozen_measurement_rejects_omitted_scenario(self):
        plan = {'runs': 8, 'seconds': 30, 'warmup_seconds': 5, 'scenarios': ['plaintext']}
        args = Namespace(runs=8, seconds=30, warmup_seconds=5, scenario=['plaintext'])
        remote.check_measurement({'measurement': plan}, args)
        # Omitting the filter selects all workloads and must fail before starting any server.
        args.scenario = None
        with self.assertRaises(ValueError):
            remote.check_measurement({'measurement': plan}, args)

    def test_frozen_duration_requires_exact_match(self):
        plan = {'runs': 8, 'seconds': 30, 'warmup_seconds': 5, 'scenarios': ['plaintext']}
        for duration in (29, 30, 31):
            args = Namespace(runs=8, seconds=duration, warmup_seconds=5, scenario=['plaintext'])
            if duration == 30:
                remote.check_measurement({'measurement': plan}, args)
            else:
                with self.assertRaises(ValueError):
                    remote.check_measurement({'measurement': plan}, args)

    def test_cpu_list_contract(self):
        # Single CPU, range, duplicate and disjoint sets; malformed/reversed ranges rejected.
        for text, expected in [("0", {0}), ("0-1", {0, 1}), ("1,1,3", {1, 3})]:
            self.assertEqual(linux_server.cpu_list(text), expected)
        for text in ["", "-1", "1-0", "0;id", "65536"]:
            with self.assertRaises(ValueError):
                linux_server.cpu_list(text)

    def test_memory_positive_integer_boundary(self):
        config = dict(BUDGET, user="bench", executable="/tmp/server", working_directory="/tmp")
        for value, accepted in [(0, False), (1, True), (2, True), (-1, False), (True, False)]:
            config["memory_bytes"] = value
            if accepted:
                argv = linux_server.start_command(config)
                self.assertIn(f"--property=MemoryMax={value}", argv)
            else:
                with self.assertRaises(ValueError):
                    linux_server.start_command(config)

    def test_effective_limits_and_oom(self):
        remote.check_resources(SNAPSHOT, BUDGET)
        # Effective limits must equal the declared budget, not merely be bounded by it.
        for key, values in [("memory.max", ["1048575", "1048577"]),
                            ("cpu.max", ["199999 100000", "200001 100000"]),
                            ("cpuset.cpus.effective", ["2", "2-4"]),
                            ("memory.swap.max", ["1"]),
                            ("memory.events", ["oom 1\noom_kill 0", "oom 0\noom_kill 1"])]:
            for value in values:
                data = copy.deepcopy(SNAPSHOT)
                data["cgroup"][key] = value
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    remote.check_resources(data, BUDGET)

    def test_warmup_failure_still_stops_server(self):
        config = {"host": "127.0.0.1", "port": 8080, "budget": BUDGET,
                  "snapshot": ["snapshot"], "stop": ["stop"]}
        with patch.object(remote, "control", side_effect=[{}, {"stopped": True}]) as control, \
             patch.object(remote.bench, "validate_response"), \
             patch.object(remote.bench, "run_oha", return_value={"valid": False}):
            result = remote.trial(config, {"start": ["start"]}, remote.bench.SCENARIOS[0], "oha", 1, 1)
        self.assertFalse(result["valid"])
        self.assertTrue(result["stop"]["stopped"])
        self.assertEqual(control.call_args.args[0], ["stop"])

    def test_cleanup_failure_invalidates_successful_load(self):
        config = {"host": "127.0.0.1", "port": 8080, "budget": BUDGET,
                  "snapshot": ["snapshot"], "stop": ["stop"]}
        with patch.object(remote, "control", side_effect=[{}, SNAPSHOT, SNAPSHOT, RuntimeError("stop failed")]), \
             patch.object(remote.bench, "validate_response"), \
             patch.object(remote.bench, "run_oha", return_value={"valid": True}):
            result = remote.trial(config, {"start": ["start"]}, remote.bench.SCENARIOS[0], "oha", 1, 1)
        self.assertFalse(result["valid"])
        self.assertIn("cleanup_error", result)


if __name__ == "__main__":
    unittest.main()
