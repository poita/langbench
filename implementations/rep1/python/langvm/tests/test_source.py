import pytest

from langvm.diagnostics import CompileError
from langvm.source import split_lines, split_modules


def test_split_lines_handles_crlf_and_final_line():
    assert split_lines("") == []
    assert split_lines("a\r\nb") == ["a", "b"]
    assert split_lines("a\n") == ["a"]
    assert split_lines("a\n\n") == ["a", ""]
    assert split_lines("a\r") == ["a\r"]  # unterminated final line keeps its CR


def test_two_modules_in_order():
    mods = split_modules("@module a\nx\n@module b\n\ny\n")
    assert [(m.name, m.lines) for m in mods] == [("a", ["x"]), ("b", ["", "y"])]


@pytest.mark.parametrize(
    "text, expected",
    [
        ("", "bad-module at 1:1"),
        ("fn main() {}", "bad-module at 1:1"),
        ("@module fn\n", "bad-module at 1:1"),
        ("@module a \n", "bad-module at 1:1"),
        ("@module a\nx\n@oops\n", "bad-module at 3:1"),
        ("@module a\n@module  b\n", "bad-module at 2:1"),
        ("@module a\n@module a\n", "dup-module at 2:1"),
        ("@module a\n@module b\n@module a\n@bad\n", "bad-module at 4:1"),
    ],
)
def test_pass0_errors(text, expected):
    with pytest.raises(CompileError) as info:
        split_modules(text)
    assert str(info.value) == "error: " + expected


def test_end_position():
    (m,) = split_modules("@module a\nabc\nde")
    assert m.end_position() == (2, 3)
    (m,) = split_modules("@module a\n")
    assert m.end_position() == (1, 1)
