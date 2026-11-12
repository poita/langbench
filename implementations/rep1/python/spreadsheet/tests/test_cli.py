import subprocess
import sys
from pathlib import Path

from spreadsheet.cli import run_commands

SRC = Path(__file__).resolve().parents[1] / "src"


def test_run_commands():
    out = run_commands(["set A1 1", "set B1 =A1+1", "get B1", "get Z9", "dump", "clear A1", "dump"])
    assert out == ["2", "", "A1 1", "B1 2", "B1 1"]


def run_cli(data: bytes) -> bytes:
    return subprocess.run(
        [sys.executable, "-m", "spreadsheet"],
        input=data,
        capture_output=True,
        check=True,
        env={"PYTHONPATH": str(SRC)},
    ).stdout


def test_cli_without_trailing_newline_and_unicode():
    out = run_cli('set A1 "héllo x"\nset B1 =A1&"😀"\nget B1'.encode())
    assert out.decode() == "héllo x😀\n"


def test_cli_no_output():
    assert run_cli(b"set A1 1\n") == b""
