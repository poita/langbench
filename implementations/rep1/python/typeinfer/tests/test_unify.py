import pytest

from typeinfer import OccursError, UnifyError, format_type
from typeinfer.scheme import generalize, instantiate
from typeinfer.typerep import BOOL, GENERIC, INT, TCon, TVar, arrow, list_of, resolve, tuple_of
from typeinfer.unify import unify


def test_binds_variable():
    a = TVar(1)
    unify(a, INT)
    assert resolve(a) is INT


def test_constructor_mismatch():
    with pytest.raises(UnifyError):
        unify(INT, BOOL)
    with pytest.raises(UnifyError):
        unify(tuple_of([INT, INT]), tuple_of([INT, INT, INT]))
    with pytest.raises(UnifyError):
        unify(list_of(INT), INT)


def test_occurs():
    a = TVar(1)
    with pytest.raises(OccursError):
        unify(a, list_of(a))
    with pytest.raises(OccursError):
        unify(a, arrow(INT, tuple_of([BOOL, a])))


def test_left_to_right_order():
    a = TVar(1)
    with pytest.raises(OccursError):  # first components before second
        unify(tuple_of([a, INT]), tuple_of([list_of(a), BOOL]))


def test_levels_are_lowered():
    a, b = TVar(1), TVar(5)
    unify(a, list_of(b))
    assert b.level == 1


def test_shared_dag_unification_is_fast():
    def tower(n):
        t = TVar(1)
        for _ in range(n):
            t = tuple_of([t, t])
        return t

    x, y = tower(60), tower(60)  # 2**60 leaves if expanded
    unify(x, y)


def test_generalize_and_instantiate():
    a, b = TVar(2), TVar(1)
    t = arrow(a, arrow(b, a))
    assert generalize(t, 1) is True
    assert a.level == GENERIC and b.level == 1
    c = instantiate(t, 3)
    assert format_type(c) == "'a -> 'b -> 'a"
    assert c.args[0].level == 3 and c.args[0] is not a
    assert resolve(c.args[1].args[0]) is b


def test_instantiate_shares_and_preserves_sharing():
    closed = list_of(INT)
    a = TVar(GENERIC)
    inner = tuple_of([a, a])
    t = tuple_of([closed, inner, inner])
    c = instantiate(t, 1)
    assert c.args[0] is closed
    assert c.args[1] is c.args[2]
    assert c.args[1].args[0] is c.args[1].args[1]
    assert not generalize(INT, 0)
