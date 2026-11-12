import pytest

from datalog import Atom, Comparison, Const, Not, ParseError, Var, parse, parse_atom
from datalog.parser import tokenize


def test_tokenize_longest_match_and_negative_numbers():
    toks = [t for _, t in tokenize("p(X):-X<-1,X<=a.")]
    assert toks == ["p", "(", "X", ")", ":-", "X", "<", "-1", ",", "X", "<=", "a", "."]


def test_comments_and_whitespace_between_clauses():
    prog = parse("% hi\np(a). q(b).%x\n\n?- p(X).  % end")
    assert [str(r) for r in prog.rules] == ["p(a).", "q(b)."]
    assert [str(q) for q in prog.queries] == ["?- p(X)."]


def test_empty_program():
    prog = parse("  % nothing\n")
    assert prog.rules == () and prog.queries == ()


def test_rule_body_literals():
    (rule,) = parse("p(X) :- q(X, 3), not r(X), X != a, 2 < X.").rules
    q, neg, c1, c2 = rule.body
    assert q == Atom("q", (Var("X"), Const(3)))
    assert neg == Not(Atom("r", (Var("X"),)))
    assert c1 == Comparison("!=", Var("X"), Const("a"))
    assert c2 == Comparison("<", Const(2), Var("X"))


def test_constant_starting_comparison_vs_atom():
    (rule,) = parse("p(X) :- q(X), a = X.").rules
    assert rule.body[1] == Comparison("=", Const("a"), Var("X"))


def test_anonymous_variables_are_distinct_and_clause_scoped():
    (rule,) = parse("p(X) :- q(X, _, _).").rules
    a, b = rule.body[0].args[1:]
    assert a != b and isinstance(a, Var)


def test_not_prefixed_identifiers_are_ordinary():
    (rule,) = parse("p(nothing) :- q(not_x).").rules
    assert rule.head.args == (Const("nothing"),)


def test_integers():
    (f,) = parse("p(0, -5, 1000000000).").rules
    assert [t.value for t in f.head.args] == [0, -5, 1000000000]


def test_parse_atom():
    assert parse_atom("path(1, X)") == Atom("path", (Const(1), Var("X")))
    with pytest.raises(ParseError):
        parse_atom("p(1) q(2)")


@pytest.mark.parametrize("text", ["p(a)", "p(.", "p(a) :- .", "p() .", "p(a) :- X.", "#"])
def test_malformed(text):
    with pytest.raises(ParseError):
        parse(text)
