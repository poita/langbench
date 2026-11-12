import os
import subprocess
import sys
from pathlib import Path

SRC = Path(__file__).resolve().parent.parent / "src"


def run_cli(stdin: bytes) -> subprocess.CompletedProcess:
    env = dict(os.environ, PYTHONPATH=str(SRC))
    return subprocess.run(
        [sys.executable, "-m", "scheme_interp"],
        input=stdin,
        capture_output=True,
        env=env,
        timeout=60,
    )


def test_cli_prints_values_and_exits_zero():
    p = run_cli(b'(display "hi") (newline) (+ 1 2)')
    assert (p.returncode, p.stdout) == (0, b"hi\n3\n")


def test_cli_error_exit_code_is_zero():
    p = run_cli(b'(display "x") (car 1)')
    assert (p.returncode, p.stdout) == (0, b"xerror: type-error\n")


def test_cli_utf8_roundtrip():
    p = run_cli('(display "héllo ✓")'.encode("utf-8"))
    assert p.stdout.decode("utf-8") == "héllo ✓"
