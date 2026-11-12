"""The initial environment."""

from __future__ import annotations

from .typerep import BOOL, GENERIC, INT, Scheme, TVar, Type, arrow, list_of, tuple_of


def initial_bindings() -> dict[str, Scheme]:
    """Fresh type schemes for the built-in functions."""

    def v() -> TVar:
        return TVar(GENERIC)

    def poly(t: Type) -> Scheme:
        return Scheme(t, True)

    table: dict[str, Scheme] = {}
    table["not"] = Scheme(arrow(BOOL, BOOL))
    a, b = v(), v()
    table["fst"] = poly(arrow(tuple_of([a, b]), a))
    table["snd"] = poly(arrow(tuple_of([a, b]), b))
    a = v()
    table["hd"] = poly(arrow(list_of(a), a))
    table["tl"] = poly(arrow(list_of(a), list_of(a)))
    table["null"] = poly(arrow(list_of(a), BOOL))
    table["length"] = poly(arrow(list_of(a), INT))
    a, b = v(), v()
    table["map"] = poly(arrow(arrow(a, b), arrow(list_of(a), list_of(b))))
    table["fold"] = poly(
        arrow(arrow(a, arrow(b, a)), arrow(a, arrow(list_of(b), a)))
    )
    return table
