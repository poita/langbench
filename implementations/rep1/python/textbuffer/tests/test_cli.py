import subprocess
import sys
from pathlib import Path

import pytest

from textbuffer import CommandError, decode_text, parse_input

ROOT = Path(__file__).resolve().parent.parent

EXAMPLE_1 = """2
hello world
second line
move end
insert !
move down
insert  (edited)
goto 0 5
insert ,
print
delete
delete
print
"""

EXPECTED_1 = """hello, world!
second line (edited)
cursor 0 6
--
hell world!
second line (edited)
cursor 0 4
--
"""


def test_example_one(run):
    assert run(EXAMPLE_1) == EXPECTED_1


def test_empty_document_and_no_print(run):
    assert run("0\ninsert hi\n") == ""
    assert run("0\nprint") == "\ncursor 0 0\n--\n"


def test_document_lines_may_look_like_commands(run):
    assert run("2\nprint\n undo \nprint\n") == "print\n undo \ncursor 0 0\n--\n"


def test_missing_trailing_newline(run):
    assert run("1\nabc\nmove end\ninsert d\nprint") == "abcd\ncursor 0 4\n--\n"


def test_decode_text():
    assert decode_text("a\\nb\\\\n") == "a\nb\\n"
    assert decode_text("plain") == "plain"


def test_parse_input():
    assert parse_input("2\na\n\nmove left\n") == (["a", ""], ["move left"])


@pytest.mark.parametrize("cmd", ["bogus", "move sideways", "goto 1", "goto a b", "move left selec"])
def test_bad_commands(run, cmd):
    with pytest.raises(CommandError):
        run(f"1\nx\n{cmd}\n")


def test_cli_subprocess():
    proc = subprocess.run(
        [str(ROOT / "run.sh")], input=EXAMPLE_1.encode(), capture_output=True, check=True
    )
    assert proc.stdout.decode() == EXPECTED_1
