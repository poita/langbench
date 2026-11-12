import pytest

from jtemplate.errors import TemplateSyntaxError
from jtemplate.lexer import TagItem, TextItem, lex


def texts(source):
    return [i.text for i in lex(source) if isinstance(i, TextItem)]


def test_plain_text_and_tags():
    items = lex("a{{ x }}b{% if y %}c")
    assert [type(i) for i in items] == [TextItem, TagItem, TextItem, TagItem, TextItem]
    assert items[1].tokens == [("name", "x")]
    assert items[3].opener == "{%"


def test_comment_is_dropped():
    assert texts("a{# anything {{ #}b") == ["a", "b"]


def test_whitespace_control():
    assert texts("a  \n {{- x -}} \n b") == ["a", "b"]
    assert texts("a {#- c -#} b") == ["a", "b"]


def test_dash_only_affects_adjacent_text():
    assert texts("a {{ x -}}{# c #} b") == ["a ", " b"]


def test_closer_wins_over_minus():
    items = lex("{{ x -}}")
    assert items[0].tokens == [("name", "x")]


def test_string_escapes_and_closer_inside_string():
    (item,) = lex(r'{{ "a\n\"%}\\" }}')
    assert item.tokens == [("str", 'a\n"%}\\')]


@pytest.mark.parametrize(
    "source",
    ["{{ x", "{# x", "{{ 'a", r"{{ '\q' }}", "{{ @ }}", "{{{ x }}}", "{% if %"],
)
def test_lex_errors(source):
    with pytest.raises(TemplateSyntaxError):
        lex(source)


def test_numbers_and_operators():
    (item,) = lex("{{ 1 2.5 ** // != }}")
    assert item.tokens == [("int", 1), ("float", 2.5), ("op", "**"), ("op", "//"), ("op", "!=")]


def test_keywords():
    (item,) = lex("{{ not true and x }}")
    assert [t[0] for t in item.tokens] == ["kw", "kw", "kw", "name"]
