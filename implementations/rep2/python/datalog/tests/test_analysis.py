import pytest

from datalog import StratificationError, UnsafeRuleError, evaluate, parse
from datalog.analysis import check_safety, stratify


@pytest.mark.parametrize("src", [
    "p(X) :- q(Y).",
    "p(X).",
    "p(_).",
    "p(X) :- q(X), not r(Y).",
    "p(X) :- q(X), not r(_).",
    "p(Y) :- q(X), X = Y.",
    "p(X) :- q(X), Y = 5.",
    "p(X) :- q(X), X < _.",
    "p(X) :- not q(X).",
])
def test_unsafe(src):
    with pytest.raises(UnsafeRuleError):
        check_safety(parse(src))


@pytest.mark.parametrize("src", [
    "p(1).",
    "p(X) :- q(X, _).",
    "p(X) :- q(X), not r(X), X < 3.",
    "p(1) :- 1 < 2.",
])
def test_safe(src):
    check_safety(parse(src))


@pytest.mark.parametrize("src", [
    "win(X) :- move(X, Y), not win(Y).",
    "p(X) :- q(X), not r(X). r(X) :- q(X), not p(X).",
    "a(X) :- b(X). b(X) :- c(X). c(X) :- d(X), not a(X).",
])
def test_unstratifiable(src):
    with pytest.raises(StratificationError):
        stratify(parse(src))


def test_components_dependencies_first():
    prog = parse("c(X) :- b(X), not a(X). b(X) :- a(X). a(1).")
    order = [comp[0] for comp in stratify(prog)]
    assert order.index(("a", 1)) < order.index(("b", 1)) < order.index(("c", 1))


def test_mutual_recursion_is_one_component():
    prog = parse("even(X) :- odd(Y), s(Y, X). odd(X) :- even(Y), s(Y, X).")
    comps = [set(c) for c in stratify(prog)]
    assert {("even", 1), ("odd", 1)} in comps


def test_different_arities_are_different_predicates():
    # r/1 negatively depends on r/2, which is a distinct, empty predicate.
    model = evaluate(parse("q(1). r(X) :- q(X), not r(X, X)."))
    assert model.relation("r", 1) == [(1,)]
