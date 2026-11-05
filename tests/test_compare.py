import csv
import importlib.util
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("compare", os.path.join(HERE, "..", "tools", "compare.py"))
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)

FIELDS = ["root", "lang", "slug", "input", "status", "wall_min", "wall_med", "cpu_min", "instr_min", "cycles_min",
          "rss_mb", "runs"]


def row(lang, slug, inp, cycles, status="ok"):
    return {"root": "r", "lang": lang, "slug": slug, "input": inp, "status": status, "wall_min": cycles / 1e9,
            "wall_med": cycles / 1e9, "cpu_min": 0.1, "instr_min": cycles * 2, "cycles_min": cycles, "rss_mb": 10,
            "runs": 3}


def write_tag(d, rows):
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "runs.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, FIELDS)
        w.writeheader()
        w.writerows(rows)


class Ratios(unittest.TestCase):
    def test_ratios_are_per_input_against_the_baseline(self):
        rows = [row("go", "sat", "1", 100), row("d", "sat", "1", 50), row("go", "sat", "2", 100),
                row("d", "sat", "2", 200)]
        r = cp.ratios(rows, "cycles_min", "go")
        self.assertEqual(sorted(r["d"]["sat"]), [0.5, 2.0])
        self.assertNotIn("go", r)

    def test_wrong_outputs_and_missing_baselines_are_skipped(self):
        rows = [row("go", "sat", "1", 100), row("d", "sat", "1", 50, status="wrong"), row("d", "toml", "1", 70)]
        self.assertEqual(cp.ratios(rows, "cycles_min", "go"), {})

    def test_summary_geomean_and_slower_count(self):
        rows = [row("go", "sat", "1", 100), row("d", "sat", "1", 50), row("go", "toml", "1", 100),
                row("d", "toml", "1", 200)]
        s = cp.summary(cp.ratios(rows, "cycles_min", "go"))
        self.assertAlmostEqual(s["d"]["gmean"], 1.0)
        self.assertEqual(s["d"]["problems"], 2)
        self.assertEqual(s["d"]["slower"], 1)


class Timeouts(unittest.TestCase):
    def test_timeout_counts_as_a_lower_bound(self):
        rows = [row("go", "sat", "1", 100), row("python", "sat", "1", 6000, status="timeout")]
        r, lower = cp.ratios(rows, "cycles_min", "go", with_bounds=True)
        self.assertEqual(r["python"]["sat"], [60.0])
        self.assertEqual(lower, {("python", "sat", "1")})
        self.assertEqual(cp.summary(r, lower)["python"]["lower_bounds"], 1)

    def test_baseline_timeout_is_skipped(self):
        rows = [row("go", "sat", "1", 100, status="timeout"), row("rust", "sat", "1", 80)]
        r, lower = cp.ratios(rows, "cycles_min", "go", with_bounds=True)
        self.assertEqual(r, {})


class ShortInputs(unittest.TestCase):
    def test_lists_inputs_where_the_fastest_correct_run_is_short(self):
        rows = [row("go", "sat", "1", 4e9), row("rust", "sat", "1", 3e9), row("go", "toml", "1", 6e9)]
        self.assertEqual(cp.short_inputs(rows, 5.0), [("sat", "1", 3.0)])


class Report(unittest.TestCase):
    def test_report_marks_lower_bounds(self):
        with tempfile.TemporaryDirectory() as d:
            write_tag(d, [row("go", "sat", "1", 100), row("python", "sat", "1", 6000, status="timeout")])
            self.assertIn(">=", cp.report(d, "cycles", "go"))

    def test_report_combines_comma_separated_tags(self):
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            write_tag(a, [row("go", "sat", "1", 100)])
            write_tag(b, [row("python", "sat", "1", 900)])
            self.assertIn("9.00", cp.report(f"{a},{b}", "cycles", "go"))

    def test_report_reads_a_tag_directory(self):
        with tempfile.TemporaryDirectory() as d:
            write_tag(d, [row("go", "sat", "1", 100), row("rust", "sat", "1", 80)])
            text = cp.report(d, "cycles", "go")
            self.assertIn("Rust", text)
            self.assertIn("0.80", text)


if __name__ == "__main__":
    unittest.main()
