import pytest

from langvm import syntax as S
from langvm.patterns import irrefutable, normalize, useful
from langvm.types import BOOL, INT, TList


def lit(v):
    return S.PLit((1, 1), "int", v)


def wild():
    return S.PWild((1, 1))


def lst(n, rest=False):
    return S.PList((1, 1), [wild() for _ in range(n)], rest, None, None)


def rows(*pats):
    return [(normalize(p),) for p in pats]


def test_int_literals_never_exhaustive():
    assert useful(rows(lit(0), lit(1)), (None,), (INT,))
    assert not useful(rows(lit(0), wild()), (None,), (INT,))


def test_bool_columns():
    t, f = S.PLit((1, 1), "bool", True), S.PLit((1, 1), "bool", False)
    assert not useful(rows(t, f), (None,), (BOOL,))
    assert useful(rows(t), (None,), (BOOL,))


@pytest.mark.parametrize(
    "arms, exhaustive",
    [
        ([lst(0), lst(1), lst(2, True)], True),
        ([lst(0), lst(1, True), lst(0, True)], True),
        ([lst(1), lst(2, True)], False),
        ([lst(0, True)], True),
    ],
)
def test_list_rule(arms, exhaustive):
    assert (not useful(rows(*arms), (None,), (TList(INT),))) == exhaustive


def test_redundant_list_arm_is_not_useful():
    r = rows(lst(1, True))
    assert not useful(r, (normalize(lst(2)),), (TList(INT),))
    assert not useful(r, (normalize(lst(3, True)),), (TList(INT),))
    assert useful(rows(lst(2, True)), (normalize(lst(1)),), (TList(INT),))


def test_irrefutable():
    assert irrefutable(wild())
    assert irrefutable(lst(0, True)) and not irrefutable(lst(1, True))
    assert not irrefutable(lit(1))
