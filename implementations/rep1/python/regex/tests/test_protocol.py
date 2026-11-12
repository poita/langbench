import io
import subprocess
import sys
from pathlib import Path

from btregex.protocol import format_match, parse_input, run
import btregex

ROOT = Path(__file__).resolve().parent.parent

EXAMPLE_IN = """3
(a|ab)(c|bcd)(d*)
1
abcd
a*
2
bbb

^(a+)+$
2
aaaa
aaab
"""
EXAMPLE_OUT = """match 0 4|0,1|1,4|4,4
match 0 0
match 0 0
match 0 4|0,4
no
"""


def test_parse_input_is_strictly_positional():
    text = "3\n\n2\n \n12\n 3 \n0\n5\n0\n"
    assert list(parse_input(text)) == [("", [" ", "12"]), (" 3 ", []), ("5", [])]


def test_format_match():
    assert format_match(None) == "no"
    m = btregex.compile("(a)|(b)").search("b")
    assert format_match(m) == "match 0 1|-|0,1"
    assert format_match(btregex.compile("a").search("a")) == "match 0 1"


def test_run_example():
    assert "".join(run(EXAMPLE_IN)) == EXAMPLE_OUT


def test_zero_subjects_produce_no_output():
    assert "".join(run("2\nx\n0\ny\n1\ny\n")) == "match 0 1\n"


def test_cli_end_to_end():
    result = subprocess.run(
        [sys.executable, "-m", "btregex"],
        input=EXAMPLE_IN, capture_output=True, text=True, check=True,
        env={"PYTHONPATH": str(ROOT / "src"), "PATH": ""},
    )
    assert result.stdout == EXAMPLE_OUT
