"""Lexer and parser: logical lines, tokens, blocks, which E_PARSE is reported."""

import pytest

from kiln import KilnError
from kiln.lexer import lex_file, tokenize
from kiln.parser import parse_file


def parse_error(source: str) -> str:
    with pytest.raises(KilnError) as info:
        parse_file(b"f.kiln", source.encode())
    assert info.value.kind == "E_PARSE"
    return info.value.detail.decode()


def test_comments_and_blank_lines():
    lines = lex_file(b"f", b"# c\n\nlet a = 1 # trailing\n  \nlet b = '#'  \n")
    assert [n for n, _ in lines] == [3, 5]
    assert lines[1][1][-1] == ("STR", b"'#'")


def test_multiline_brackets_join_logical_line():
    lines = lex_file(b"f", b"let a = f(\n 1,\n 2)\nlet b = 2\n")
    assert [n for n, _ in lines] == [1, 4]


def test_hash_inside_interpolation_is_content():
    assert len(lex_file(b"f", b'let a = "{ "#" }"\n')) == 1


def test_operators_longest_match():
    kinds = [k for k, _ in tokenize(b"a |> b || c ++ d <= e == f != g >= h")]
    assert kinds == ["ID", "|>", "ID", "||", "ID", "++", "ID", "<=", "ID", "==", "ID", "!=", "ID", ">=", "ID"]


@pytest.mark.parametrize(
    "source,line",
    [
        ('let b = f(\n  "unterminated\n)\n', 1),
        ("let a = (1\n", 1),
        ("let a = 1)\n", 1),
        ("let a = 1 | 2\n", 1),
        ("let a = 1 & 2\n", 1),
        ("let a = 1 $ 2\n", 1),
        ("let = 1\nlet x = \"abc\n", 2),          # lexical errors beat grammar errors
        ("let = 1\n", 1),
        ("let a = 1\nlet b = \n", 2),
        ("when true {\n", 1),
        ("when true {\n  step {\n", 2),            # innermost open block
        ("when true {\n} otherwise {\n", 2),
        ("}\n", 1),
        ("{\n", 1),
        ("when true {\n} foo\n", 2),
        ("each x in [] {\n} otherwise {\n}\n", 2),
        ("when true {\n} otherwise {\n} elsewhen true {\n}\n", 3),
        ("when true {\n} otherwise {\n} otherwise {\n}\n", 3),
        ("out 1\n", 1),
        ("step {\n  let a = 1\n}\n", 2),
        ("step {\n  step {\n  }\n}\n", 2),
        ("let a = 1 2\n", 1),
        ("let in = 1\n", 1),
        ("let a = cost\n", 1),
        ('let a = "\\q"\n', 1),
        ('let a = "}"\n', 1),
        ('let a = "{}"\n', 1),
        ('let a = "{ }"\n', 1),
        ('let a = "{1 2}"\n', 1),
        ("let a = f(1)(2)\n", 1),
        ("let a = [1](0)\n", 1),
        ("each a, a in [] {\n}\n", 1),
        ("rule r(a, a) {\n}\n", 1),
        ("rule r(a = 1, b) {\n}\n", 1),
        ("use r(a = 1, 2)\n", 1),
        ("let a = 1 |> 2\n", 1),
    ],
)
def test_parse_error_lines(source, line):
    assert parse_error(source) == f"f.kiln:{line}"


@pytest.mark.parametrize(
    "source",
    [
        "let a = 1 |> cost\n",                 # a pipe target is always a call name
        "let a = true(1)\n",
        "use cost(1)\n",                       # rule names in `use` may be reserved words
        "step {\n  cmd in()\n}\n",
        "rule r(a, b = a, c = 1,) {\n}\n",
        "use r(1, k = 2,)\n",
        'let a = "{{x}} \\n \\t \\\\ \\" \\0 \\r"\n',
        "let a = 'it''s'\n",
        'let a = "{join(xs, ", ")}"\n',
        "when a {\n} elsewhen b {\n} elsewhen c {\n} otherwise {\n}\n",
    ],
)
def test_valid_syntax(source):
    parse_file(b"f.kiln", source.encode())


def test_empty_file():
    assert parse_file(b"f", b"") == ()
