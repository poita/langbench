"""Syntax tree of KBL."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Union

# -- expressions ------------------------------------------------------------


@dataclass(slots=True)
class Literal:
    """A constant value: ``int``, ``bool`` or a string without interpolation."""

    value: object


@dataclass(slots=True)
class Interp:
    """A double-quoted literal with interpolations: bytes or expression parts."""

    parts: list[Union[bytes, "Expr"]]


@dataclass(slots=True)
class Var:
    name: bytes


@dataclass(slots=True)
class ListExpr:
    items: list["Expr"]


@dataclass(slots=True)
class Unary:
    op: bytes
    operand: "Expr"


@dataclass(slots=True)
class Binary:
    op: bytes
    left: "Expr"
    right: "Expr"


@dataclass(slots=True)
class Index:
    target: "Expr"
    index: "Expr"


@dataclass(slots=True)
class Call:
    """A built-in call; ``a |> f(b)`` is parsed as ``Call(f, [a, b])``."""

    name: bytes
    args: list["Expr"]


Expr = Union[Literal, Interp, Var, ListExpr, Unary, Binary, Index, Call]

# -- statements ---------------------------------------------------------------


@dataclass(slots=True)
class Let:
    name: bytes
    expr: Expr


@dataclass(slots=True)
class Set:
    name: bytes
    expr: Expr


@dataclass(slots=True)
class Include:
    expr: Expr


@dataclass(slots=True)
class Abort:
    expr: Expr


@dataclass(slots=True)
class Default:
    expr: Expr


@dataclass(slots=True)
class Phony:
    name: bytes
    expr: Expr


@dataclass(slots=True)
class Use:
    name: bytes
    #: ``(keyword or None, expression)`` pairs in source order.
    args: list[tuple[bytes | None, Expr]]


@dataclass(slots=True)
class When:
    #: ``(condition, body)`` for ``when`` and each ``elsewhen``.
    branches: list[tuple[Expr, list["Stmt"]]]
    otherwise: list["Stmt"] | None = None


@dataclass(slots=True)
class Each:
    index_name: bytes | None
    name: bytes
    subject: Expr
    body: list["Stmt"]


@dataclass(slots=True)
class Param:
    name: bytes
    default: Expr | None


@dataclass(slots=True)
class Rule:
    name: bytes
    params: list[Param]
    body: list["Stmt"]


@dataclass(slots=True)
class StepField:
    """One line of a ``step`` block.

    ``kind`` is ``out``, ``in``, ``after``, ``cost``, ``depfile`` or ``cmd``;
    ``cmd`` fields also carry the command name and argument expressions.
    """

    kind: str
    expr: Expr | None = None
    cmd_name: bytes = b""
    cmd_args: list[Expr] = field(default_factory=list)


@dataclass(slots=True)
class Step:
    fields: list[StepField]


Stmt = Union[Let, Set, Include, Abort, Default, Phony, Use, When, Each, Rule, Step]
