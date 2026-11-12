import pytest

from datalog import Atom, Comparison, Literal, ParseError, Rule, Variable, parse
from datalog.lexer import tokenize


def kinds(src):
    return [(t.kind, t.text) for t in tokenize(src)]


def test_longest_match_operators():
    assert [t for _, t in kinds("X<-1")] == ["X", "<", "-1"]
    assert [t for _, t in kinds("X<=Y")] == ["X", "<=", "Y"]
    assert [t for _, t in kinds("p(X):-q(X).")][3:5] == [")", ":-"]
    assert [t for _, t in kinds("?-p(1).")][0] == "?-"


def test_keyword_vs_identifier():
    assert kinds("not nothing not_x")[0][0] == "not"
    assert [k for k, _ in kinds("not nothing not_x")] == ["not", "ident", "ident"]


def test_comments_and_whitespace():
    assert kinds("a % comment ( ) \n\t\r b") == [("ident", "a"), ("ident", "b")]
    assert kinds("   % only a comment") == []


def test_bad_character():
    with pytest.raises(ParseError):
        list(tokenize("p(a) # x"))


def test_parse_fact_rule_query():
    prog = parse("e(1, a). p(X) :- e(X, _), not q(X), X != 3. ?- p(Y).")
    assert prog.rules[0] == Rule(Atom("e", (1, "a")))
    rule = prog.rules[1]
    assert rule.head == Atom("p", (Variable("X"),))
    assert isinstance(rule.body[0], Literal) and not rule.body[0].negated
    assert rule.body[1].negated
    assert rule.body[2] == Comparison("!=", Variable("X"), 3)
    assert prog.queries == [Atom("p", (Variable("Y"),))]


def test_anonymous_variables_are_distinct():
    prog = parse("p(X) :- q(_, _, X).")
    args = prog.rules[0].body[0].atom.args
    assert args[0] != args[1]


def test_negative_integers_and_zero():
    prog = parse("p(-5, 0, 12).")
    assert prog.rules[0].head.args == (-5, 0, 12)


def test_comparison_between_constants_starting_with_identifier():
    prog = parse("p(X) :- q(X), a < X.")
    assert prog.rules[0].body[1] == Comparison("<", "a", Variable("X"))


def test_empty_program():
    prog = parse("")
    assert prog.rules == [] and prog.queries == []


@pytest.mark.parametrize("src", ["p(1)", "p(1,).", "p(.", "p() .", "p(X) :- .", "?- p(1)"])
def test_malformed(src):
    with pytest.raises(ParseError):
        parse(src)
