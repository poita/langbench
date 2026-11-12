import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(data: bytes):
    env = dict(os.environ, PYTHONPATH=str(ROOT / "src"))
    p = subprocess.run([sys.executable, "-m", "jsoncanon"], input=data,
                       capture_output=True, env=env)
    return p.returncode, p.stdout


def test_valid():
    assert run(b' { "b" : 1 , "a" : [ ] } ') == (0, b'{"a":[],"b":1}\n')


def test_invalid():
    assert run(b"[1,]") == (0, b"invalid\n")
    assert run(b"\xff") == (0, b"invalid\n")
    assert run(b"") == (0, b"invalid\n")


def test_unclosed_deep():
    assert run(b"[" * 100000) == (0, b"invalid\n")
