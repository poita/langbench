import pytest

from jtemplate import nodes as n
from jtemplate.errors import TemplateSyntaxError, UnknownFilterError
from jtemplate.parser import parse_template


def expr(source):
    (node,) = parse_template("t", "{{ " + source + " }}").body
    return node.expr


def test_precedence_filter_binds_tighter_than_multiplication():
    node = expr("a * b|int")
    assert isinstance(node, n.BinOp) and isinstance(node.right, n.FilterCall)


def test_unary_minus_before_filter_and_power():
    assert isinstance(expr("-x|int"), n.FilterCall)
    node = expr("-2 ** 2")
    assert isinstance(node, n.BinOp) and isinstance(node.left, n.Neg)


def test_power_is_left_associative():
    node = expr("2 ** 3 ** 2")
    assert isinstance(node.left, n.BinOp)


def test_concat_binds_tighter_than_plus():
    node = expr("1 + 2 ~ 3")
    assert node.op == "+" and node.right.op == "~"


def test_comparison_chain_and_not_in():
    node = expr("a < b not in c")
    assert isinstance(node, n.Compare) and len(node.rest) == 2


def test_blocks_table_and_filters_collected():
    t = parse_template("t", "{% block a %}{% block b %}{{ x|upper }}{% endblock %}{% endblock a %}")
    assert set(t.blocks) == {"a", "b"}
    assert t.filters == {"upper"}


@pytest.mark.parametrize(
    "source",
    [
        "{% if x %}",
        "{% endif %}",
        "{% for a, b in x %}{% endfor %}",
        "{% for x in y if z %}{% endfor %}",
        "{% set a, b = 1 %}",
        "{% raw %}",
        "{% include 'x' ignore missing %}",
        "{% block a %}{% endblock b %}",
        "{% block a %}{% endblock %}{% block a %}{% endblock %}",
        "{% extends 'a' %}{% extends 'b' %}",
        "{% if x %}{% extends 'a' %}{% endif %}",
        "{% macro m(a, a) %}{% endmacro %}",
        "{{ f(a=1, 2) }}",
        "{{ f(a=1, a=2) }}",
        "{{ a if b else c }}",
        "{{ (1, 2) }}",
        "{{ x is odd }}",
        "{{ x - }}",
        "{{ }}",
        "{% %}",
        "{% else %}",
        "{% if x %}{% else %}{% else %}{% endif %}",
        "{{ x.true }}",
        "{{ [1, 2,] }}",
    ],
)
def test_syntax_errors(source):
    with pytest.raises(TemplateSyntaxError):
        parse_template("t", source)


def test_unknown_filter_is_checked_after_parsing():
    with pytest.raises(UnknownFilterError):
        parse_template("t", "{% if false %}{{ x|nope }}{% endif %}")
    with pytest.raises(TemplateSyntaxError):  # syntax wins over filter
        parse_template("t", "{{ x|nope }}{% if %}")
