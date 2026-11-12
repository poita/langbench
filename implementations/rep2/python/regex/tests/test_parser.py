import pytest

from btregex import PatternSyntaxError
from btregex.ast import Alt, Any, Bol, Char, CharSet, Eol, Group, Repeat, Seq
from btregex.parser import parse


def test_precedence_and_group_numbering():
    tree, groups = parse("a(b|c)*|d")
    assert groups == 1
    assert isinstance(tree, Alt)
    seq = tree.branches[0]
    assert isinstance(seq, Seq)
    rep = seq.items[1]
    assert isinstance(rep, Repeat) and (rep.min, rep.max) == (0, None)
    assert isinstance(rep.child, Group) and rep.child.index == 1


def test_groups_numbered_by_open_paren():
    tree, groups = parse("((a)(b))(c)")
    assert groups == 4
    outer = tree.items[0]
    assert outer.index == 1
    assert [g.index for g in outer.child.items] == [2, 3]
    assert tree.items[1].index == 4


@pytest.mark.parametrize("pattern", ["", "|", "a|", "()", "(|b)", "||"])
def test_empty_branches_allowed(pattern):
    parse(pattern)


def test_counted_quantifiers():
    for text, lo, hi in [("a{3}", 3, 3), ("a{2,}", 2, None), ("a{0,0}", 0, 0),
                         ("a{2,100}", 2, 100)]:
        tree, _ = parse(text)
        assert (tree.min, tree.max) == (lo, hi)


def test_classes():
    chars = parse("[a-c-]")[0].chars
    assert chars == frozenset("abc-")
    assert parse("[-a]")[0].chars == frozenset("-a")
    assert parse(r"[\-x]")[0].chars == frozenset("-x")
    assert parse(r"[a^]")[0].chars == frozenset("a^")
    assert parse(r"[\]\[\\]")[0].chars == frozenset("][\\")
    neg = parse("[^a]")[0].chars
    assert "a" not in neg and "b" in neg and len(neg) == 127
    d = parse(r"[\d_]")[0].chars
    assert d == frozenset("0123456789_")


def test_escapes():
    assert isinstance(parse(r"\.")[0], Char)
    assert parse(r"\ ")[0].char == " "
    assert parse(r"\d")[0].chars == frozenset("0123456789")
    assert "a" in parse(r"\D")[0].chars and "1" not in parse(r"\D")[0].chars
    assert parse(r"\s")[0].chars == frozenset(" \t\n\r\f\v")


def test_atoms():
    tree, _ = parse("^.$")
    assert [type(i) for i in tree.items] == [Bol, Any, Eol]
    assert isinstance(parse("[a]")[0], CharSet)


@pytest.mark.parametrize("pattern", [
    "*", "a**", "a+?", "^*", "$+", "(*)", "|*", "(a", "a)", "[a", r"\q",
    "a{2,1}", "a{", "a{x}", "a\\", "}",
])
def test_syntax_errors(pattern):
    with pytest.raises(PatternSyntaxError):
        parse(pattern)
