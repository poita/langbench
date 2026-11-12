"""Generalisation and instantiation of type schemes (level-based)."""

from __future__ import annotations

from .typerep import GENERIC, TCon, TVar, Type, new_stamp, resolve


def generalize(t: Type, level: int) -> bool:
    """Quantify every unbound variable of ``t`` whose level exceeds ``level``.

    Quantified variables get the level :data:`GENERIC`.  The walk visits each
    distinct node of ``t`` once and never looks at the environment.  Returns
    ``True`` if at least one variable was quantified.
    """
    return _generalize(t, level, new_stamp())


def _generalize(t: Type, level: int, stamp: int) -> bool:
    t = resolve(t)
    if t.__class__ is TVar:
        if t.level > level:  # type: ignore[attr-defined]
            if t.level != GENERIC:  # type: ignore[attr-defined]
                t.level = GENERIC  # type: ignore[attr-defined]
            return True
        return False
    if t.mark == stamp or not t.args:  # type: ignore[attr-defined]
        return False
    t.mark = stamp  # type: ignore[attr-defined]
    found = False
    for arg in t.args:  # type: ignore[attr-defined]
        if _generalize(arg, level, stamp):
            found = True
    return found


def instantiate(t: Type, level: int) -> Type:
    """Copy ``t``, replacing each quantified variable by a fresh one at ``level``.

    Each distinct node is visited once, so sharing in ``t`` is preserved in
    the copy, and sub-terms without quantified variables are shared with the
    original rather than copied.
    """
    memo: dict[int, Type] = {}

    def go(t: Type) -> Type:
        t = resolve(t)
        if t.__class__ is TVar:
            if t.level != GENERIC:  # type: ignore[attr-defined]
                return t
            copy = memo.get(id(t))
            if copy is None:
                copy = memo[id(t)] = TVar(level)
            return copy
        args = t.args  # type: ignore[attr-defined]
        if not args:
            return t
        copy = memo.get(id(t))
        if copy is not None:
            return copy
        new_args = [go(a) for a in args]
        for old, new in zip(args, new_args):
            if new is not old and new is not resolve(old):
                copy = TCon(t.name, tuple(new_args))  # type: ignore[attr-defined]
                break
        else:
            copy = t
        memo[id(t)] = copy
        return copy

    return go(t)
