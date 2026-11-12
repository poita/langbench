import pytest

from typeset import CodexaError
from typeset.inline import C, D, M, R, S, FootnoteCounter, scan_inline


def scan(text, **kw):
    return scan_inline(text, lambda i: (1, i + 1), "document.cdx", FootnoteCounter(), **kw)


def err(text, **kw):
    with pytest.raises(CodexaError) as info:
        scan(text, **kw)
    return info.value.format()


def test_spaces_collapse_and_trim():
    units = scan("  a   b  ")
    assert [u[0] for u in units] == [C, S, C]


def test_styles_compose():
    units = scan("{b|{i|x}}y")
    assert units[0][2] == (True, True, False, "")
    assert units[1][2] == (False, False, False, "")


def test_size_steps_are_recorded_in_order():
    assert scan("{+|{-|x}}")[0][2][3] == "+-"


def test_escapes_and_nbsp():
    units = scan(r"a\{\ b~\-c")
    assert [u[0] for u in units] == [C, C, R, C, R, D, C]
    assert units[1][1] == "{"


def test_footnote_mark_and_fresh_style():
    units = scan("a{b|x{n|note {i|it}}}")
    mark = units[2]
    assert mark[0] == M and mark[1].number == 1
    assert mark[2] == (True, False, False, "")
    assert [u[0] for u in mark[1].units] == [C, C, C, C, S, C, C]


@pytest.mark.parametrize("text,expected", [
    ("{z|x}", "document.cdx:1:1: unknown-inline"),
    ("a {b|x", "document.cdx:1:3: unclosed-inline"),
    ("{b|{i|x}", "document.cdx:1:1: unclosed-inline"),
    ("x}", "document.cdx:1:2: stray-brace"),
    ("ab\\", "document.cdx:1:3: bad-escape"),
    ("a\\q", "document.cdx:1:2: bad-escape"),
    ("{n|a{n|b}}", "document.cdx:1:5: nested-footnote"),
])
def test_errors(text, expected):
    assert err(text) == expected


def test_footnote_not_allowed():
    assert err("x {n|a}", allow_footnote=False) == "document.cdx:1:3: footnote-not-allowed"
