"""Acceptance tests: zero/positive counts, transport/HTTP failures, and preservation."""
import copy
import importlib.util
from pathlib import Path
import unittest
import tempfile
import json
import hashlib
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("bench_run", Path(__file__).with_name("run.py"))
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def raw(count=1):
    return {"summary": {"requestsPerSec": 10, "successRate": 1, "slowest": 0.2},
            "latencyPercentiles": {"p50": 0.01, "p99": 0.1},
            "statusCodeDistribution": {"200": count}, "errorDistribution": {}}


class AcceptanceTests(unittest.TestCase):
    def test_process_window_does_not_claim_traffic_phase_boundaries(self):
        # Successful, malformed, and failed outputs all retain process bounds.
        for stdout, code in [(json.dumps(raw()), 0), ('truncated', 0), (json.dumps(raw()), 1)]:
            with patch.object(bench.subprocess, 'Popen') as popen, \
                 patch.object(bench.time, 'monotonic_ns', side_effect=[10, 20, 40, 50]):
                process = popen.return_value.__enter__.return_value
                process.returncode = code
                process.communicate.return_value = (stdout, '')
                result = bench.run_oha('oha', 8080, 'GET', '/plaintext', 64, None, '1s')
            timing = result['timing']
            self.assertEqual([timing[k] for k in ('spawn_begin_ns', 'spawn_returned_ns',
                             'output_collected_ns', 'parse_finished_ns')], [10, 20, 40, 50])
            self.assertIsNone(timing['active_traffic_begin_ns'])
            self.assertIsNone(timing['active_traffic_end_ns'])

    def test_fixed_rate_correction_and_delivery_boundary(self):
        # Target delivery has a fixed 99% minimum, checked below/at/above that boundary.
        for achieved in (98, 99, 100):
            value = raw(achieved)
            value['summary']['requestsPerSec'] = achieved
            with patch.object(bench.subprocess, 'Popen') as popen:
                process = popen.return_value.__enter__.return_value
                process.returncode = 0
                process.communicate.return_value = (json.dumps(value), '')
                result = bench.run_oha('oha', 8080, 'GET', '/plaintext', 64, None, '1s', rate=100)
                self.assertEqual(result['offered_load']['target_met'], achieved >= 99)
                command = popen.call_args.args[0]
                self.assertIn('--latency-correction', command)
                self.assertEqual(command[command.index('-q') + 1], '100')

    def test_interrupted_load_reaps_child_and_preserves_output(self):
        with patch.object(bench.subprocess, 'Popen') as popen:
            process = popen.return_value.__enter__.return_value
            process.returncode = -9
            process.communicate.side_effect = [KeyboardInterrupt(), ('partial output', 'diagnostic')]
            result = bench.run_oha('oha', 8080, 'GET', '/plaintext', 64, None, '1s')
            process.kill.assert_called_once()
            self.assertEqual(process.communicate.call_count, 2)
            self.assertFalse(result['valid'])
            self.assertTrue(result['interrupted'])
            self.assertEqual(result['stdout'], 'partial output')
            self.assertEqual(result['stderr'], 'diagnostic')

    def test_completed_count_boundary(self):
        # Zero is the rejection boundary; one is the smallest accepted count.
        for count, valid in [(0, False), (1, True), (2, True)]:
            with self.subTest(count=count):
                self.assertEqual(bench.load_result(raw(count))["valid"], valid)

    def test_error_classes_are_retained_and_rejected(self):
        # Deadline aborts, timeouts, and connection failures must all invalidate a trial.
        for error in ["aborted due to deadline", "timeout", "connection reset"]:
            value = raw()
            value["errorDistribution"] = {error: 1}
            result = bench.load_result(value)
            self.assertFalse(result["valid"])
            self.assertEqual(result["errors"], {error: 1})
            self.assertEqual(result["raw"], value)

    def test_http_failure_even_with_successful_transport(self):
        value = raw()
        value["statusCodeDistribution"]["500"] = 1
        self.assertFalse(bench.load_result(value)["valid"])

    def test_partial_success_rejected(self):
        value = raw()
        value["summary"]["successRate"] = 0.99
        self.assertFalse(bench.load_result(value)["valid"])

    def test_throughput_domain(self):
        for throughput in [-1, 0, float("nan"), float("inf")]:
            value = raw()
            value["summary"]["requestsPerSec"] = throughput
            self.assertFalse(bench.load_result(value)["valid"])

    def test_latency_domain_and_order(self):
        # Zero is valid; negative/nonfinite values and reversed percentile order are invalid.
        for value, accepted in [(-0.001, False), (0, True), (0.001, True),
                                (float("nan"), False), (float("inf"), False), (0.11, False)]:
            result = raw()
            result["latencyPercentiles"]["p50"] = value
            self.assertEqual(bench.load_result(result)["valid"], accepted)

    def test_summary_keeps_latency_from_same_trial(self):
        rows = [bench.load_result(raw()) for _ in range(3)]
        for row, rps, p99 in zip(rows, [30, 10, 20], [100, 300, 200]):
            row.update(rps=rps, p99_ms=p99)
        self.assertIs(bench.median_run(rows), rows[2])
        failed = copy.deepcopy(rows)
        failed[0]["valid"] = False
        with self.assertRaises(ValueError):
            bench.median_run(failed)
        with self.assertRaises(ValueError):
            bench.median_run([])

    def test_response_contract(self):
        # Independent mismatches: status, media type, body, and excess trailing bytes.
        for status, media, body, accepted in [
            (200, "text/plain; charset=utf-8", b"Hello, World!", True),
            (500, "text/plain", b"Hello, World!", False),
            (200, "application/json", b"Hello, World!", False),
            (200, "text/plain", b"wrong", False),
            (200, "text/plain", b"Hello, World!x", False),
        ]:
            with patch.object(bench.http.client, "HTTPConnection") as connection:
                response = connection.return_value.getresponse.return_value
                response.status = status
                response.getheader.return_value = media
                response.read.return_value = body
                if accepted:
                    bench.validate_response(1234, "GET", "/plaintext", None)
                else:
                    with self.assertRaises(ValueError):
                        bench.validate_response(1234, "GET", "/plaintext", None)
                connection.return_value.close.assert_called_once()


class ProvenanceTests(unittest.TestCase):
    def test_only_matching_binary_manifest_is_attached(self):
        # Missing, stale, and matching manifests are distinct provenance states.
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "server"
            binary.write_bytes(b"current")
            self.assertEqual(bench.build_provenance(binary)["build_provenance"], [])
            manifest = Path(directory) / "build-manifest-test.json"
            manifest.write_text(json.dumps({"binaries": {"server": "stale"}}))
            self.assertEqual(bench.build_provenance(binary)["build_provenance"], [])
            manifest.write_text(json.dumps({"binaries": {
                "server": hashlib.sha256(b"current").hexdigest()}}))
            self.assertEqual(len(bench.build_provenance(binary)["build_provenance"]), 1)


class ProcessMetricsTests(unittest.TestCase):
    def test_tree_membership(self):
        from process_metrics import select_tree
        # Root-only servers, nested workers, and unrelated processes must be distinguished.
        rows = {10: {"ppid": 1, "rss_kib": 100},
                11: {"ppid": 10, "rss_kib": 20},
                12: {"ppid": 11, "rss_kib": 30},
                13: {"ppid": 1, "rss_kib": 999}}
        self.assertEqual([p["pid"] for p in select_tree(rows, 10)], [10, 11, 12])
        self.assertEqual([p["pid"] for p in select_tree(rows, 13)], [13])
        self.assertEqual(select_tree(rows, 99), [])

    def test_sampler_failure_is_explicit(self):
        from process_metrics import ProcessSampler
        from threading import Event
        # A failed snapshot must not become a plausible zero-memory measurement.
        sampler = ProcessSampler(10)
        sampled = Event()
        def unavailable(_root):
            sampled.set()
            raise OSError("unavailable")
        with patch("process_metrics.snapshot", side_effect=unavailable):
            sampler.start()
            self.assertTrue(sampled.wait(5))
            result = sampler.stop()
        self.assertFalse(result["valid"])
        self.assertIsNone(result["sampled_peak_summed_rss_kib"])
        self.assertTrue(result["errors"])


if __name__ == "__main__":
    unittest.main()
