import subprocess
import sys
from pathlib import Path

from orderbook import run

SRC = Path(__file__).resolve().parent.parent / "src"

EXAMPLE_IN = """9
LIMIT s1 SELL 101 5
LIMIT s2 SELL 103 5
LIMIT s3 SELL 102 5
LIMIT s4 SELL 104 5
LIMIT b1 BUY 103 12
BOOK
LIMIT b2 BUY 110 1
LIMIT b3 BUY 103 9
BOOK
"""
EXAMPLE_OUT = """REST s1
REST s2
REST s3
REST s4
TRADE b1 s1 101 5
FILLED s1
TRADE b1 s3 102 5
FILLED s3
TRADE b1 s2 103 2
FILLED b1
ASK 103 3 1
ASK 104 5 1
--
TRADE b2 s2 103 1
FILLED b2
TRADE b3 s2 103 2
FILLED s2
REST b3
BID 103 7 1
ASK 104 5 1
--
"""


def cli(stdin: str, *args: str):
    return subprocess.run(
        [sys.executable, "-m", "orderbook", *args],
        input=stdin.encode(), capture_output=True, env={"PYTHONPATH": str(SRC)},
    )


def test_run_example():
    assert run(EXAMPLE_IN) == EXAMPLE_OUT


def test_cli_example():
    r = cli(EXAMPLE_IN)
    assert r.returncode == 0
    assert r.stdout.decode() == EXAMPLE_OUT


def test_cli_no_final_newline():
    assert cli("1\nBOOK").stdout == b"--\n"


def test_cli_empty_stream_outputs_nothing():
    r = cli("0\n")
    assert r.returncode == 0 and r.stdout == b""


def test_cli_rejects_arguments():
    assert cli("0\n", "x").returncode == 2
