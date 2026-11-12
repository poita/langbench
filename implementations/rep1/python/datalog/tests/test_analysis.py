import pytest

from datalog import StratificationError, UnsafeRuleError, parse
from datalog.analysis import check_safety, is_safe, stratify


def rules(text):
    return parse(text).rules


@pytest.mark.parametrize("text", [
    "p(X).",
    "p(X) :- q(Y).",
    "p(X) :- q(X), not r(X, Y).",
    "p(X) :- q(X), not r(_).",
    "p(Y) :- q(X), X = Y.",
    "p(X) :- q(X), Y = 5.",
    "p(X) :- q(X), X < _.",
    "p(_) :- q(1).",
])
def test_unsafe(text):
    assert not all(is_safe(r) for r in rules(text))
    with pytest.raises(UnsafeRuleError):
        check_safety(rules(text))


@pytest.mark.parametrize("text", [
    "p(a).",
    "p(X) :- q(X, _), not r(X), X < 3.",
    "p(a) :- 1 < 2.",
    "p(X) :- not q(a), r(X).",
])
def test_safe(text):
    check_safety(rules(text))


def test_components_in_dependency_order():
    comps = stratify(rules("a(X) :- b(X). b(X) :- c(X), not d(X). c(X) :- c(X), e(X)."))
    pos = {p: i for i, comp in enumerate(comps) for p in comp}
    assert pos[("c", 1)] < pos[("b", 1)] and pos[("d", 1)] < pos[("b", 1)]
    assert pos[("b", 1)] < pos[("a", 1)]


def test_mutual_recursion_forms_one_component():
    comps = stratify(rules("e(X) :- o(X). o(X) :- e(X)."))
    assert any(set(c) == {("e", 1), ("o", 1)} for c in comps)


@pytest.mark.parametrize("text", [
    "win(X) :- move(X, Y), not win(Y).",
    "p(X) :- q(X). q(X) :- r(X), not p(X).",
    "p(X) :- n(X), not p(X).",
])
def test_unstratifiable(text):
    with pytest.raises(StratificationError):
        stratify(rules(text))


def test_arity_distinguishes_predicates():
    stratify(rules("p(X) :- q(X), not p(X, X)."))
