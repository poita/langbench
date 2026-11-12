"""End-to-end tests of the command-line tool via ``python -m bigint``."""

import os
import subprocess
import sys
from pathlib import Path

import pytest

from bigint.cli import evaluate

SRC = Path(__file__).resolve().parent.parent / "src"


def run_cli(stdin: str) -> str:
    env = dict(os.environ, PYTHONPATH=str(SRC))
    done = subprocess.run(
        [sys.executable, "-m", "bigint"],
        input=stdin.encode(),
        capture_output=True,
        env=env,
        check=True,
    )
    return done.stdout.decode()


def test_spec_example_1():
    assert run_cli("12 + 30\n5 - 7\n-7 / 2\n-7 % 2\n") == "42\n-2\n-3\n-1\n"


def test_spec_example_2():
    out = run_cli(
        "-0 + 0\n007 cmp 7\n-5 * 0\n99999999999999999999 + 1\n2 ^ 10\n0 ^ 0\n"
    )
    assert out == "0\n0\n0\n100000000000000000000\n1024\n1\n"


def test_spec_example_3_errors_and_big_product():
    out = run_cli(
        "1 / 0\n0 % 0\n2 ^ -1\n"
        "-123456789012345678901234567890 * 987654321098765432109876543210\n"
        "1000000000000000000000000000000 - 1\n-3 cmp -2"
    )
    assert out.split("\n") == [
        "error",
        "error",
        "error",
        "-121932631137021795226185032733622923332237463801111263526900",
        "999999999999999999999999999999",
        "-1",
        "",
    ]


def test_empty_input_prints_nothing():
    assert run_cli("") == ""


def test_missing_final_newline():
    assert run_cli("1 + 1") == "2\n"


@pytest.mark.parametrize(
    "line, expected",
    [
        ("5 ^ -0", "1"),
        ("-0 ^ -00", "1"),
        ("5 / -0", "error"),
        ("5 % -000", "error"),
        ("5 ^ -3", "error"),
        ("-0 cmp 0", "0"),
        ("-1 / 2", "0"),
        ("-7 % 7", "0"),
        ("-7 % -2", "-1"),
        ("007 * -000", "0"),
    ],
)
def test_evaluate(line, expected):
    assert evaluate(line) == expected
