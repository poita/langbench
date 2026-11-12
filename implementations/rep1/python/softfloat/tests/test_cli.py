import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(text, *args):
    env = dict(os.environ, PYTHONPATH=str(ROOT / "src"))
    return subprocess.run(
        [sys.executable, "-m", "softfloat", *args],
        input=text, capture_output=True, text=True, env=env,
    )


def test_examples():
    r = run("add 3f800000 3f800000\nsqrt 40000000\ndiv 3f800000 80000000")
    assert r.returncode == 0
    assert r.stdout == "40000000\n3fb504f3\nff800000\n"


def test_trailing_newline_ok():
    assert run("sub 3f800000 3f800000\n").stdout == "00000000\n"


def test_bad_line_fails():
    r = run("bogus 00000000 00000000\n")
    assert r.returncode == 1
    assert "line 1" in r.stderr
