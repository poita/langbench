import subprocess
import sys
from pathlib import Path

import pytest

from bigint import QueryError, evaluate_queries, evaluate_query

SRC = str(Path(__file__).resolve().parent.parent / "src")


def run_cli(stdin: str) -> str:
    return subprocess.run(
        [sys.executable, "-m", "bigint"],
        input=stdin.encode(),
        capture_output=True,
        check=True,
        env={"PYTHONPATH": SRC},
    ).stdout.decode()


def test_spec_examples():
    assert run_cli("12 + 30\n5 - 7\n-7 / 2\n-7 % 2\n") == "42\n-2\n-3\n-1\n"
    assert (
        run_cli("-0 + 0\n007 cmp 7\n-5 * 0\n99999999999999999999 + 1\n2 ^ 10\n0 ^ 0\n")
        == "0\n0\n0\n100000000000000000000\n1024\n1\n"
    )
    assert (
        run_cli(
            "1 / 0\n0 % 0\n2 ^ -1\n"
            "-123456789012345678901234567890 * 987654321098765432109876543210\n"
            "1000000000000000000000000000000 - 1\n-3 cmp -2\n"
        )
        == "error\nerror\nerror\n"
        "-121932631137021795226185032733622923332237463801111263526900\n"
        "999999999999999999999999999999\n-1\n"
    )


def test_empty_input_and_missing_final_newline():
    assert run_cli("") == ""
    assert run_cli("1 + 1") == "2\n"


def test_zero_exponent_forms():
    assert run_cli("5 ^ -0\n-0 ^ -00\n5 / -0\n") == "1\n1\nerror\n"


def test_evaluate_query_api():
    assert evaluate_query("2 ^ 64") == "18446744073709551616"
    with pytest.raises(QueryError):
        evaluate_query("1 % 0")
    with pytest.raises(ValueError):
        evaluate_query("1 ? 2")
    assert list(evaluate_queries(["1 / 0", "4 / 2"])) == ["error", "2"]
