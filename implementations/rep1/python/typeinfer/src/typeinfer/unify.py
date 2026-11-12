"""Union-find unification with an occurs check and level adjustment."""

from __future__ import annotations

from .errors import OccursError, UnifyError
from .typerep import TCon, TVar, Type, new_stamp, resolve


def unify(a: Type, b: Type) -> None:
    """Make ``a`` and ``b`` equal, or raise :class:`UnifyError` / :class:`OccursError`.

    Components are unified left to right, each completely before the next.
    Whenever a variable is bound, the other type is walked once: that walk
    performs the occurs check and lowers the levels of the variables it
    reaches to the level of the bound variable.

    After two constructor nodes have been unified they are linked, so a later
    unification of the same pair of (shared) sub-terms costs O(1).
    """
    a = resolve(a)
    b = resolve(b)
    if a is b:
        return
    if a.__class__ is TVar:
        _bind(a, b)  # type: ignore[arg-type]
        return
    if b.__class__ is TVar:
        _bind(b, a)  # type: ignore[arg-type]
        return
    assert isinstance(a, TCon) and isinstance(b, TCon)
    args_a = a.args
    args_b = b.args
    if a.name != b.name or len(args_a) != len(args_b):
        raise UnifyError()
    if not args_a:
        return
    for x, y in zip(args_a, args_b):
        unify(x, y)
    a.link = b


def _bind(var: TVar, t: Type) -> None:
    if t.__class__ is TVar:
        if t.level > var.level:  # type: ignore[attr-defined]
            t.level = var.level  # type: ignore[attr-defined]
    else:
        _adjust(t, var, var.level, new_stamp())
    var.link = t


def _adjust(t: Type, var: TVar, level: int, stamp: int) -> None:
    """Occurs check for ``var`` in ``t`` and lowering of levels to ``level``.

    Visits every distinct node of ``t`` once.
    """
    t = resolve(t)
    if t.__class__ is TVar:
        if t is var:
            raise OccursError()
        if t.level > level:  # type: ignore[attr-defined]
            t.level = level  # type: ignore[attr-defined]
        return
    if t.mark == stamp:  # type: ignore[attr-defined]
        return
    t.mark = stamp  # type: ignore[attr-defined]
    for arg in t.args:  # type: ignore[attr-defined]
        _adjust(arg, var, level, stamp)
