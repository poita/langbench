import os
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class TimeLimit(unittest.TestCase):
    def test_every_test_has_a_120_second_limit_by_default(self):
        """CONVENTIONS.md promises a uniform per-test limit, which catches hangs; it is not a speed target."""
        out = subprocess.run([sys.executable, os.path.join(ROOT, "run_tests.py"), "--help", "--", "x"], capture_output=True,
                             text=True).stdout
        self.assertIn("default: 120", out)
        self.assertIn("120 seconds", open(os.path.join(ROOT, "CONVENTIONS.md")).read())


if __name__ == "__main__":
    unittest.main()
