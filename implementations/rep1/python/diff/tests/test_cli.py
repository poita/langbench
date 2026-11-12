import os
import subprocess
import sys
from pathlib import Path

SRC = str(Path(__file__).resolve().parents[1] / "src")


def run_cli(text: str) -> subprocess.CompletedProcess:
    env = dict(os.environ, PYTHONPATH=SRC)
    return subprocess.run(
        [sys.executable, "-m", "myersdiff"],
        input=text.encode(), capture_output=True, env=env,
    )


def test_diff_example():
    p = run_cli("diff\n3\na\nb\nc\n3\na\nB \nc\n")
    assert p.returncode == 0
    assert p.stdout.decode() == "4\n a\n-b\n+B \n c\n"


def test_patch_example():
    p = run_cli("patch\n2\na\nb\n3\n a\n-b\n+  c \n")
    assert p.stdout.decode() == "2\na\n  c \n"


def test_empty_b_patch():
    assert run_cli("patch\n1\na\n1\n-a\n").stdout == b"0\n"


def test_empty_both():
    assert run_cli("diff\n0\n0\n").stdout == b"0\n"


def test_crlf_and_missing_newline():
    p = run_cli("diff\r\n1\r\nx\r\n1\r\nx")
    assert p.stdout == b"1\n x\n"


def test_malformed_fails():
    p = run_cli("nope\n0\n")
    assert p.returncode != 0 and p.stdout == b""
