import importlib.util
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
spec = importlib.util.spec_from_file_location("results_report", os.path.join(ROOT, "tools", "results_report.py"))
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)


class Findings(unittest.TestCase):
    def test_a_finding_two_runs_both_report_counts_once(self):
        f = {"kind": "banned-facility", "agent": "rep1:go:x", "detail": "y"}
        g = {"kind": "build-flags", "agent": "rep1:d:z", "detail": "w"}
        self.assertEqual(rr.merged_findings([[f, g], [dict(f)]]), [f, g])


class Committed(unittest.TestCase):
    def test_results_readme_is_what_the_tool_generates(self):
        """results/README.md is generated from implementations/; regenerate it with `make results`."""
        with open(os.path.join(ROOT, "results", "README.md")) as f:
            self.assertEqual(rr.render(os.path.join(ROOT, "implementations")), f.read())


if __name__ == "__main__":
    unittest.main()
