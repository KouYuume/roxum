"""Callgrind annotation parsing and per-request differencing contracts."""
import collections
import unittest

import instructions

ANNOTATION = """\
--------------------------------------------------------------------------------
Ir
--------------------------------------------------------------------------------
1,000 (100.0%)  PROGRAM TOTALS

--------------------------------------------------------------------------------
Ir                 file:function
--------------------------------------------------------------------------------
  600 (60.00%)  /work/platform/host/http1/parser.zig:http1.parser.Parser.feed'2 [/work/roxum]
  100 (10.00%)  /work/platform/host/http1/parser.zig:http1.parser.Parser.feed [/work/roxum]
  300 (30.00%)  ???:roc__p0123.fast [/work/roxum]
"""


class AnnotationTests(unittest.TestCase):
    def test_recursion_suffixes_merge_into_one_function(self):
        total, costs = instructions.parse_annotation(ANNOTATION)
        self.assertEqual(total, 1000)
        self.assertEqual(costs["/work/platform/host/http1/parser.zig:http1.parser.Parser.feed"], 700)
        self.assertEqual(costs["???:roc__p0123.fast"], 300)

    def test_missing_totals_is_rejected(self):
        with self.assertRaises(ValueError):
            instructions.parse_annotation(ANNOTATION.replace("PROGRAM TOTALS", "TOTALS"))


class PerRequestTests(unittest.TestCase):
    def runs(self, small_total, large_total):
        small = (small_total, collections.Counter({"a.zig:f": small_total}))
        large = (large_total, collections.Counter({"a.zig:f": large_total}))
        return small, large

    def test_request_delta_boundary(self):
        # Zero additional requests cannot be divided; one is the smallest valid delta.
        small, large = self.runs(100, 150)
        for delta in (-1, 0):
            with self.subTest(delta=delta), self.assertRaises(ValueError):
                instructions.per_request(small, large, delta)
        self.assertEqual(instructions.per_request(small, large, 1)["instructions_per_request"], 50)
        self.assertEqual(instructions.per_request(small, large, 2)["instructions_per_request"], 25)

    def test_instruction_growth_boundary(self):
        # A large run that did not execute more instructions measured nothing.
        for large_total in (99, 100):
            small, large = self.runs(100, large_total)
            with self.subTest(large_total=large_total), self.assertRaises(ValueError):
                instructions.per_request(small, large, 10)
        small, large = self.runs(100, 101)
        self.assertAlmostEqual(instructions.per_request(small, large, 10)["instructions_per_request"], 0.1)

    def test_functions_present_in_one_run_only_are_kept(self):
        small = (100, collections.Counter({"a.zig:startup": 100}))
        large = (300, collections.Counter({"a.zig:startup": 100, "/http1/parser.zig:feed": 200}))
        result = instructions.per_request(small, large, 100)
        self.assertEqual(result["categories"], {"http1 parse": 2.0, "other": 0.0})


class CategoryTests(unittest.TestCase):
    def test_inlined_code_is_attributed_by_source_file(self):
        self.assertEqual(instructions.category(
            "/work/platform/host/request_debug.zig:server.RequestFiber.start"), "connection")
        self.assertEqual(instructions.category(
            "/work/platform/host/http1/framing.zig:http1.parser.Parser.feed"), "http1 parse")

    def test_roxum_runtime_is_not_go_runtime(self):
        self.assertEqual(instructions.category("/work/platform/host/runtime.zig:runtime.tryAlloc"), "allocator")
        # Go allocation counts as allocation; the rest of its runtime has its own row.
        self.assertEqual(instructions.category("???:runtime.mallocgc"), "allocator")
        self.assertEqual(instructions.category("???:runtime.netpoll"), "go runtime")


if __name__ == "__main__":
    unittest.main()
