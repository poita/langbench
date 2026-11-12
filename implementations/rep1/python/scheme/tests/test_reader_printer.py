import pytest

from scheme_interp import SchemeSyntaxError, display_string, read_all, write_string
from scheme_interp.bignum import BigInt
from scheme_interp.values import NIL, Pair, Symbol, intern


def rt(src):
    return [write_string(d) for d in read_all(src)]


def test_atoms():
    data = read_all("42 -7 +5 007 -0 #t #f foo + - ... 1+ a.b")
    assert data[:5] == [42, -7, 5, 7, 0]
    assert data[5] is True and data[6] is False
    assert all(type(d) is Symbol for d in data[7:])
    assert [d.name for d in data[7:]] == ["foo", "+", "-", "...", "1+", "a.b"]


def test_symbols_are_interned_and_case_sensitive():
    a, b, c = read_all("foo foo Foo")
    assert a is b and a is intern("foo") and a is not c


def test_big_literal():
    (n,) = read_all("123456789012345678901234567890")
    assert type(n) is BigInt
    assert write_string(n) == "123456789012345678901234567890"


def test_lists_and_dots():
    assert rt("(1 2 . 3) () (1 . (2 . (3 . ()))) '(a . b)") == [
        "(1 2 . 3)",
        "()",
        "(1 2 3)",
        "(quote (a . b))",
    ]


def test_quote_shorthand_nested():
    assert rt("''a '() '(1 'x)") == [
        "(quote (quote a))",
        "(quote ())",
        "(quote (1 (quote x)))",
    ]


def test_strings_and_escapes():
    (s,) = read_all(r'"a\"b\\c\nd\te"')
    assert s == 'a"b\\c\nd\te'
    assert write_string(s) == r'"a\"b\\c\nd\te"'
    assert display_string(s) == s


def test_comments_and_whitespace():
    assert read_all("; hi\n1 ;x\r\n\t2 ; end") == [1, 2]


def test_raw_newline_in_string():
    assert read_all('"a\nb"') == ["a\nb"]


def test_display_vs_write_nested():
    (d,) = read_all("""'("x" y (1 . "z"))""")
    inner = d.cdr.car
    assert write_string(inner) == '("x" y (1 . "z"))'
    assert display_string(inner) == "(x y (1 . z))"


def test_deep_nesting_does_not_overflow():
    depth = 50_000
    (d,) = read_all("(" * depth + ")" * depth)
    n = 0
    while type(d) is Pair:
        d = d.car
        n += 1
    assert n == depth - 1 and d is NIL


def test_unbalanced_input_is_a_syntax_error():
    with pytest.raises(SchemeSyntaxError):
        read_all("(1 2")
    with pytest.raises(SchemeSyntaxError):
        read_all(")")
