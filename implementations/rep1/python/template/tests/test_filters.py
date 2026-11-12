import pytest

from jtemplate import TemplateError


@pytest.mark.parametrize(
    "expr, expected",
    [
        ('"aBc"|upper', "ABC"),
        ('"aBc"|lower', "abc"),
        ('"\t a b \n"|trim', "a b"),
        ("html|escape", "&lt;a href=&#39;x&#39;&gt;&amp;&#34;&lt;/a&gt;"),
        ('"a-b-c"|replace("-", "+")', "a+b+c"),
        ('"aaa"|replace("aa", "b")', "ba"),
        ('"héllo"|length', "5"),
        ("[1, 2, 3]|length", "3"),
        ("data|length", "2"),
        ('"12"|int', "12"),
        ('" -7 "|int', "-7"),
        ('"3.9"|int', "3"),
        ('"-3.9"|int', "-3"),
        ('"1.5e2"|int', "150"),
        ('"abc"|int', "0"),
        ("2.7|int", "2"),
        ("-2.7|int", "-2"),
        ("true|int", "1"),
        ("none|int", "0"),
        ("[1, 'a']|join", "1a"),
        ("[1, 'a']|join('-')", "1-a"),
        ('"abc"|join(",")', "a,b,c"),
        ("data|join(',')", "x,y"),
        ("[3, 4]|first", "3"),
        ("[3, 4]|last", "4"),
        ('"abc"|first', "a"),
        ('"abc"|reverse', "cba"),
        ("[1, 2, 3]|reverse|join(',')", "3,2,1"),
        ("[3, 1.5, 2]|sort", "[1.5, 2, 3]"),
        ("['b', 'A', 'a']|sort", "['A', 'a', 'b']"),
        ("data|sort", "['x', 'y']"),
        ("[]|sort", "[]"),
        ("zzz|default", ""),
        ("zzz|default('d')", "d"),
        ("0|default('d')", "0"),
        ("[]|first|default('none')", "none"),
        ('" x "|trim|upper', "X"),
    ],
)
def test_filter(render, expr, expected):
    assert render("{{ " + expr + " }}", {"data": {"x": 1, "y": 2}, "html": "<a href='x'>&\"</a>"}) == expected


@pytest.mark.parametrize(
    "expr, kind",
    [
        ("5|length", "type"),
        ("none|length", "type"),
        ("5|join", "type"),
        ("5|first", "type"),
        ("[1, 'a']|sort", "type"),
        ("[[1]]|sort", "type"),
        ('"a"|upper(1)', "type"),
        ('"a"|replace("a")', "type"),
        ("x|default(1, 2)", "type"),
        ("zzz|upper", "undefined"),
        ("zzz|upper(1)", "undefined"),
        ("zzz|length", "undefined"),
    ],
)
def test_filter_errors(error_kind, expr, kind):
    assert error_kind("{{ " + expr + " }}", {"x": 1}) == kind


def test_unknown_filter_in_dead_branch(error_kind):
    assert error_kind("{% if false %}{{ 1|nope }}{% endif %}") == "filter"


def test_error_is_a_template_error(render):
    with pytest.raises(TemplateError):
        render("{{ 1|nope }}")
