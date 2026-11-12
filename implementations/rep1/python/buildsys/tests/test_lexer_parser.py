import pytest

from kiln import KilnError, parse_file
from kiln import nodes as n
from kiln.lexer import logical_lines, tokenize


def perr(src: str) -> str:
    with pytest.raises(KilnError) as exc:
        parse_file(b"f.kiln", src.encode())
    assert exc.value.kind == "E_PARSE"
    return exc.value.detail.decode()


def test_comments_and_blank_lines_are_dropped():
    lines = logical_lines(b"f", b"# c\n\nlet a = 1 # trailing\n")
    assert [ln for ln, _ in lines] == [3]


def test_hash_inside_string_is_content():
    (stmt,) = parse_file(b"f", b'let a = "x#y" # c\n')
    assert stmt.expr == n.Literal(b"x#y")


def test_brackets_join_logical_lines():
    lines = logical_lines(b"f", b"let a = f(\n 1,\n 2)\nlet b = 1\n")
    assert [ln for ln, _ in lines] == [1, 4]


def test_unterminated_literal_reported_at_first_line_of_group():
    assert perr('let b = f(\n  "unterminated\n)\n') == "f.kiln:1"


def test_lexical_errors_beat_earlier_grammar_errors():
    assert perr('let = 1\nlet x = "abc\n') == "f.kiln:2"


def test_unterminated_block_reports_innermost_header():
    assert perr("each x in [1] {\n  when true {\n") == "f.kiln:2"
    assert perr("when true {\n} otherwise {\nlet a = 1\n") == "f.kiln:2"


def test_other_errors_beat_unterminated_blocks():
    assert perr("when true {\nlet = 1\n") == "f.kiln:2"


@pytest.mark.parametrize(
    "src",
    [
        "let x = 1 |",
        "let x = 1 & 2",
        "let step = 1",
        "}",
        "{",
        "step {\nlet a = 1\n}",
        "out 'x'",
        "let x = f(1)(2)",
        "let x = (f)(1)",
        'let x = "{}"',
        'let x = "{ }"',
        'let x = "a}b"',
        'let x = "\\q"',
        "rule r(a = 1, b) {\n}",
        "rule r(a, a) {\n}",
        "each a, a in [] {\n}",
        "use r(a = 1, 2)",
        "when true {\n} otherwise {\n} elsewhen true {\n}",
        "} foo",
    ],
)
def test_grammar_errors(src):
    perr(src + "\n")


def test_reserved_words_are_call_names():
    (stmt,) = parse_file(b"f", b"let x = 1 |> cost\n")
    assert stmt.expr == n.Call(b"cost", [n.Literal(1)])


def test_precedence_and_associativity():
    (stmt,) = parse_file(b"f", b"let x = 1 + 2 * 3 - 4\n")
    assert stmt.expr == n.Binary(
        b"-",
        n.Binary(b"+", n.Literal(1), n.Binary(b"*", n.Literal(2), n.Literal(3))),
        n.Literal(4),
    )


def test_pipe_is_left_associative_and_lowest():
    (stmt,) = parse_file(b"f", b"let x = a |> f |> g(1)\n")
    assert stmt.expr == n.Call(b"g", [n.Call(b"f", [n.Var(b"a")]), n.Literal(1)])


def test_string_escapes_and_interpolation():
    (stmt,) = parse_file(b"f", b'let x = "a\\n{{b}}{n + 1}\\0"\n')
    assert stmt.expr == n.Interp(
        [b"a\n{b}", n.Binary(b"+", n.Var(b"n"), n.Literal(1)), b"\0"]
    )


def test_nested_literal_in_interpolation():
    (stmt,) = parse_file(b"f", b'let x = "{join(xs, ", ")}"\n')
    assert isinstance(stmt.expr, n.Interp)


def test_single_quoted_literal():
    (stmt,) = parse_file(b"f", b"let x = 'a''b\\n{x}'\n")
    assert stmt.expr == n.Literal(b"a'b\\n{x}")


def test_when_chain_structure():
    (stmt,) = parse_file(b"f", b"when a {\n} elsewhen b {\n} otherwise {\n}\n")
    assert len(stmt.branches) == 2 and stmt.otherwise == []


def test_tokenize_operators_longest_first():
    kinds = [t[1] for t in tokenize(b"a |> b || c ++ d <= e")]
    assert kinds == [b"a", b"|>", b"b", b"||", b"c", b"++", b"d", b"<=", b"e"]
