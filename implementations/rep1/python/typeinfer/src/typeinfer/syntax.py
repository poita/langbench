"""Abstract syntax tree of the language."""

from __future__ import annotations

from dataclasses import dataclass


class Expr:
    """Base class of expression nodes."""

    __slots__ = ()


@dataclass(slots=True)
class IntLit(Expr):
    text: str


@dataclass(slots=True)
class BoolLit(Expr):
    value: bool


@dataclass(slots=True)
class UnitLit(Expr):
    pass


@dataclass(slots=True)
class NilLit(Expr):
    """The empty list ``[]``."""


@dataclass(slots=True)
class Var(Expr):
    name: str


@dataclass(slots=True)
class Tuple(Expr):
    items: list[Expr]


@dataclass(slots=True)
class ListLit(Expr):
    """``[e1; ...; en]`` with ``n >= 1``."""

    items: list[Expr]


@dataclass(slots=True)
class Fun(Expr):
    """``fun p1 ... pn -> body``."""

    params: list[str]
    body: Expr


@dataclass(slots=True)
class App(Expr):
    """``func a1 ... an``: ``n`` nested applications, left-associative."""

    func: Expr
    args: list[Expr]


@dataclass(slots=True)
class If(Expr):
    cond: Expr
    then: Expr
    orelse: Expr


@dataclass(slots=True)
class Let(Expr):
    """``let name = value in body`` (parameters are already desugared into ``Fun``)."""

    name: str
    value: Expr
    body: Expr


@dataclass(slots=True)
class LetRec(Expr):
    """``let rec name = fun ... in body``; ``value`` is always a :class:`Fun`."""

    name: str
    value: Fun
    body: Expr


@dataclass(slots=True)
class BinOp(Expr):
    """Arithmetic, comparison or boolean operator."""

    op: str
    left: Expr
    right: Expr


@dataclass(slots=True)
class Cons(Expr):
    """``head :: tail``."""

    head: Expr
    tail: Expr


@dataclass(slots=True)
class Decl:
    """A top-level declaration.

    ``name`` is ``None`` for a bare expression.  ``recursive`` is true for
    ``let rec`` (then ``expr`` is a :class:`Fun`).
    """

    name: str | None
    expr: Expr
    recursive: bool = False
