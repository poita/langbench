import pytest

from jqlite import JQSyntaxError, ast, compile_filter
from jqlite.parser import parse


def test_precedence_pipe_comma():
    n = parse("a | b, c")
    assert isinstance(n, ast.Pipe) and isinstance(n.right, ast.Comma)
    n = parse("1, 2 | f")
    assert isinstance(n, ast.Pipe) and isinstance(n.left, ast.Comma)


def test_arithmetic_precedence():
    n = parse("1 + 2 * 3")
    assert n.op == "+" and n.right.op == "*"


def test_binding_extends_right():
    n = parse(".a as $x | $x, $x")
    assert isinstance(n, ast.As) and isinstance(n.body, ast.Comma)


def test_optional_binds_to_suffix_or_try():
    assert parse(".a?").opt is True
    assert isinstance(parse("(.a)?"), ast.Try)
    n = parse(".a??")
    assert isinstance(n, ast.Try) and n.body.opt is True
    assert parse(".[]?").opt is True


def test_slices():
    assert isinstance(parse(".[1:]"), ast.Slice)
    s = parse(".[:2]")
    assert s.lo is None and s.hi is not None


def test_object_shorthand():
    n = parse("{a, $x, (.k): 1, \"s\": 2 | 3}")
    assert len(n.entries) == 4


@pytest.mark.parametrize("bad", ["", "(", ".a |", "if . then 1", "nosuchfn", "$undefined", "1 +", "{a:}", "@"])
def test_syntax_errors(bad):
    with pytest.raises(JQSyntaxError):
        compile_filter(bad)
