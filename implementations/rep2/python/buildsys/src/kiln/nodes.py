"""Syntax-tree node types produced by :mod:`kiln.parser`."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Union

__all__ = [
    "Lit", "Interp", "Var", "ListLit", "Unary", "Binary", "Call", "Index", "Expr",
    "Let", "Set", "Include", "Abort", "Default", "Phony", "Use", "When", "Each",
    "Param", "RuleDef", "StepField", "CmdField", "StepBlock", "Stmt",
]


# ---- expressions -----------------------------------------------------------

@dataclass(slots=True, frozen=True)
class Lit:
    """A literal ``int``, ``bool`` or (escape-free) ``str`` value."""
    value: object


@dataclass(slots=True, frozen=True)
class Interp:
    """A double-quoted literal with interpolations; ``parts`` are bytes or Expr."""
    parts: tuple


@dataclass(slots=True, frozen=True)
class Var:
    name: bytes


@dataclass(slots=True, frozen=True)
class ListLit:
    items: tuple


@dataclass(slots=True, frozen=True)
class Unary:
    op: str
    operand: "Expr"


@dataclass(slots=True, frozen=True)
class Binary:
    op: str
    left: "Expr"
    right: "Expr"


@dataclass(slots=True, frozen=True)
class Call:
    """A call of a built-in function (``a |> f(b)`` is ``Call(f, (a, b))``)."""
    name: bytes
    args: tuple


@dataclass(slots=True, frozen=True)
class Index:
    target: "Expr"
    index: "Expr"


Expr = Union[Lit, Interp, Var, ListLit, Unary, Binary, Call, Index]


# ---- statements ------------------------------------------------------------

@dataclass(slots=True, frozen=True)
class Let:
    name: bytes
    expr: Expr


@dataclass(slots=True, frozen=True)
class Set:
    name: bytes
    expr: Expr


@dataclass(slots=True, frozen=True)
class Include:
    expr: Expr


@dataclass(slots=True, frozen=True)
class Abort:
    expr: Expr


@dataclass(slots=True, frozen=True)
class Default:
    expr: Expr


@dataclass(slots=True, frozen=True)
class Phony:
    name: bytes
    expr: Expr


@dataclass(slots=True, frozen=True)
class Use:
    name: bytes
    args: tuple          # positional argument expressions
    kwargs: tuple        # (name, expr) pairs in source order


@dataclass(slots=True, frozen=True)
class When:
    """``branches`` is a tuple of ``(condition | None, body)``; ``None`` is ``otherwise``."""
    branches: tuple


@dataclass(slots=True, frozen=True)
class Each:
    index_name: bytes | None
    name: bytes
    subject: Expr
    body: tuple


@dataclass(slots=True, frozen=True)
class Param:
    name: bytes
    default: Expr | None


@dataclass(slots=True, frozen=True)
class RuleDef:
    name: bytes
    params: tuple
    body: tuple


@dataclass(slots=True, frozen=True)
class StepField:
    """``out``, ``in``, ``after``, ``cost`` or ``depfile`` with its expression."""
    kind: bytes
    expr: Expr


@dataclass(slots=True, frozen=True)
class CmdField:
    name: bytes
    args: tuple


@dataclass(slots=True, frozen=True)
class StepBlock:
    fields: tuple


Stmt = Union[Let, Set, Include, Abort, Default, Phony, Use, When, Each, RuleDef, StepBlock]
