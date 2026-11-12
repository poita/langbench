import pytest

from btregex import PatternSyntaxError
from btregex.nodes import (
    Alternation,
    AnyChar,
    CharClass,
    Group,
    Literal,
    Repeat,
    Sequence,
    StartAnchor,
)
from btregex.parser import parse


def test_literals_and_sequence():
    tree, groups = parse("ab")
    assert tree == Sequence((Literal("a"), Literal("b")))
    assert groups == 0


def test_empty_pattern_is_empty_sequence():
    assert parse("") == (Sequence(()), 0)


def test_alternation_with_empty_branches():
    tree, _ = parse("a||")
    assert tree == Alternation((Literal("a"), Sequence(()), Sequence(())))


def test_groups_are_numbered_by_open_paren():
    tree, groups = parse("((a)b)(c)")
    assert groups == 3
    assert tree.items[0] == Group(1, Sequence((Group(2, Literal("a")), Literal("b"))))
    assert tree.items[1] == Group(3, Literal("c"))


@pytest.mark.parametrize(
    "pattern, lo, hi",
    [("a*", 0, None), ("a+", 1, None), ("a?", 0, 1), ("a{3}", 3, 3),
     ("a{2,}", 2, None), ("a{2,5}", 2, 5), ("a{0}", 0, 0)],
)
def test_quantifiers(pattern, lo, hi):
    assert parse(pattern)[0] == Repeat(Literal("a"), lo, hi)


def test_anchor_and_dot():
    assert parse("^.")[0] == Sequence((StartAnchor(), AnyChar()))


def test_set_escapes():
    digits = parse(r"\d")[0]
    assert digits == CharClass(frozenset("0123456789"))
    assert "5" not in parse(r"\D")[0].chars and "a" in parse(r"\D")[0].chars
    assert " " in parse(r"\s")[0].chars
    assert "_" in parse(r"\w")[0].chars and "-" in parse(r"\W")[0].chars


def test_escaped_punctuation_is_literal():
    assert parse(r"\.")[0] == Literal(".")
    assert parse(r"\ ")[0] == Literal(" ")


@pytest.mark.parametrize(
    "pattern, members",
    [("[abc]", "abc"), ("[a-c]", "abc"), ("[-a]", "-a"), ("[a-]", "a-"),
     (r"[\-a]", "-a"), ("[a^]", "a^"), (r"[\]\\]", "]\\"), (r"[\da]", "0123456789a"),
     ("[a-cx-z]", "abcxyz")],
)
def test_classes(pattern, members):
    assert parse(pattern)[0] == CharClass(frozenset(members))


def test_negated_class():
    chars = parse("[^a-c]")[0].chars
    assert "a" not in chars and "d" in chars and " " in chars


@pytest.mark.parametrize("pattern", ["(a", "a)", "[a", "*a", "a{2", "a{3,2}", "\\", r"\q", "a**", "^*"])
def test_invalid_patterns(pattern):
    with pytest.raises(PatternSyntaxError):
        parse(pattern)
