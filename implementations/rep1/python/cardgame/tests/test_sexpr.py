import pytest

from cardgame.errors import DatabaseError
from cardgame.sexpr import String, Symbol, parse, render


def test_atoms_strings_and_lists():
    forms = parse('(a 12 -3 "x y" (b))')
    assert forms == [["a", 12, -3, "x y", ["b"]]]
    assert type(forms[0][0]) is Symbol
    assert type(forms[0][3]) is String


def test_comments_and_whitespace():
    assert parse("; hi\n(a ; trailing\n\t b)\f") == [["a", "b"]]


def test_semicolon_inside_string_is_text():
    assert parse('("a;b")') == [["a;b"]]


def test_atom_may_touch_string():
    assert parse('a"b"') == ["a", "b"]


def test_minus_alone_is_a_symbol():
    assert type(parse("-")[0]) is Symbol
    assert type(parse("1a")[0]) is Symbol


@pytest.mark.parametrize("text", [
    "(a", "a)", '"abc', '"a\nb"', "99999999999999999999",
    "-9223372036854775809",
])
def test_errors(text):
    with pytest.raises(DatabaseError):
        parse(text)


def test_i64_limits_accepted():
    assert parse("9223372036854775807 -9223372036854775808") == [
        2**63 - 1, -(2**63)]


def test_render_is_canonical():
    forms = parse('(a   (b "c d")\n -4)')
    assert render(forms[0]) == '(a (b "c d") -4)'
