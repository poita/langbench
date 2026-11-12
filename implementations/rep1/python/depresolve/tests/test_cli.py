import os
import subprocess
import sys
from pathlib import Path

from depresolve.cli import format_result

ROOT = Path(__file__).resolve().parent.parent


def test_format_success_and_empty():
    assert format_result("a 1.0.0:\nroot: a *\n") == "a 1.0.0\n"
    assert format_result("root:\n") == ""


def test_format_unsatisfiable():
    assert format_result("root: a *\n") == "unsatisfiable\n"


def test_module_entry_point_via_subprocess():
    env = dict(os.environ, PYTHONPATH=str(ROOT / "src"))
    proc = subprocess.run(
        [sys.executable, "-m", "depresolve"],
        input=b"b 2.1.0:\na 1.0.0: b ^2.0.0\nroot: a *\n",
        capture_output=True,
        env=env,
        check=True,
    )
    assert proc.stdout == b"a 1.0.0\nb 2.1.0\n"
