import io
import os
import subprocess
import sys

from btregex.cli import format_match, main, process
import btregex

SRC = os.path.join(os.path.dirname(__file__), "..", "src")

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


def run_main(text):
    out = io.StringIO()
    code = main([], stdin=io.StringIO(text), stdout=out)
    return code, out.getvalue()


def test_example():
    assert run_main(EXAMPLE_IN) == (0, EXAMPLE_OUT)


def test_format_match():
    assert format_match(None) == "no"
    m = btregex.search("(a)|(b)", "b")
    assert format_match(m) == "match 0 1|-|0,1"
    assert format_match(btregex.search("x", "x")) == "match 0 1"


def test_positional_format_with_odd_lines():
    # Empty and space-only lines, integer-looking subjects, zero subjects.
    lines = ["4", "", "2", "", " 5 ", "5", "2", "5", "a5", "(x)", "0", " *", "1", "  "]
    assert process(lines) == [
        "match 0 0", "match 0 0",  # empty pattern on "" and " 5 "
        "match 0 1", "match 1 2",  # pattern "5" on "5" and "a5"
        "match 0 2",               # pattern " *" on two spaces
    ]


def test_zero_subjects_gives_no_output():
    assert run_main("1\nabc\n0\n") == (0, "")


def test_pattern_with_surrounding_spaces_exact():
    lines = ["1", " a ", "3", "x a y", "a", " a "]
    assert process(lines) == ["match 1 4", "no", "match 0 3"]


def test_subprocess_end_to_end():
    env = dict(os.environ, PYTHONPATH=SRC)
    proc = subprocess.run([sys.executable, "-m", "btregex"], input=EXAMPLE_IN.encode(),
                          capture_output=True, env=env)
    assert proc.returncode == 0
    assert proc.stdout.decode() == EXAMPLE_OUT


def test_invalid_pattern_exits_nonzero():
    code, out = run_main("1\n(a\n1\na\n")
    assert code != 0 and out == ""
