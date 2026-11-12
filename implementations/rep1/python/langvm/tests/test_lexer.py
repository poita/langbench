import math

import pytest

from langvm.diagnostics import CompileError
from langvm.lexer import tokenize


def kinds(text):
    return [t.kind for t in tokenize(text)]


def vals(text):
    return [(t.kind, t.val) for t in tokenize(text)]


def err(text):
    with pytest.raises(CompileError) as info:
        tokenize(text)
    return str(info.value)


def test_keywords_identifiers_and_wildcard():
    assert kinds("fn _ _x x1 Self") == ["fn", "_", "ident", "ident", "ident"]


def test_operators_are_greedy():
    assert kinds("#[ :: .. -> == != <= >= && || << >> ++ | & <") == [
        "#[", "::", "..", "->", "==", "!=", "<=", ">=", "&&", "||", "<<", ">>", "++", "|", "&", "<"
    ]


def test_integer_literals():
    assert vals("007") == [("int", 7)]
    assert vals("1_000 0xFf 0b1_01") == [("int", 1000), ("int", 255), ("int", 5)]
    assert vals("0X1") == [("int", 0), ("ident", "X1")]
    assert vals("123abc") == [("int", 123), ("ident", "abc")]


def test_float_literals():
    assert vals("1_.5 1e1_0 1e_5") == [
        ("float", 1.5), ("float", 1e10), ("int", 1), ("ident", "e_5")
    ]
    assert vals("1. 0..3")[:2] == [("int", 1), (".", None)]
    assert vals("1e")[:2] == [("int", 1), ("ident", "e")]
    (tok,) = tokenize("1e999")
    assert tok.val == math.inf


@pytest.mark.parametrize(
    "text, expected",
    [
        ("0x_1", "bad-token at 1:1"),
        ("0b", "bad-token at 1:1"),
        ("  #x", "bad-token at 1:3"),
        ("a ?", "bad-token at 1:3"),
        ("é", "bad-token at 1:1"),
        ("9223372036854775808", "int-range at 1:1"),
        ("'ab'", "unterminated at 1:1"),
        ("''", "unterminated at 1:1"),
        ("'\\q'", "bad-escape at 1:2"),
        ('"ab\\q', "bad-escape at 1:4"),
        ('"abc', "unterminated at 1:1"),
        ('"a\nb"', "unterminated at 1:1"),
        ("x /* a /* b */ c", "unterminated at 1:3"),
        ('"\\u{110000}"', "bad-escape at 1:2"),
        ('"\\u{D800}"', "bad-escape at 1:2"),
        ('"\\u{}"', "bad-escape at 1:2"),
        ('"\\u{12"', "bad-escape at 1:2"),
        ("\\", "bad-token at 1:1"),
    ],
)
def test_lexical_errors(text, expected):
    assert err(text) == "error: " + expected


def test_strings_and_escapes():
    assert vals(r'"a\n\t\\\"\u{1F600}\0"')[0][1] == 'a\n\t\\"\U0001F600\0'
    assert vals(r"'\''")[0] == ("char", "'")


def test_nested_comments_and_positions():
    toks = tokenize("a // c\n/* x\n/* y */ */ b")
    assert [(t.val, t.line, t.col) for t in toks] == [("a", 1, 1), ("b", 3, 12)]


def test_identifier_length_limit():
    assert kinds("a" * 200) == ["ident"]
    assert err("a" * 201) == "error: bad-token at 1:1"
