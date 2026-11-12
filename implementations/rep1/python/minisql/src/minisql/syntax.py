"""Syntax tree produced by the parser (names are unresolved)."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterator

from .values import Value


# --------------------------------------------------------------- expressions


class Node:
    """Base class of expression nodes."""

    __slots__ = ()

    def children(self) -> tuple["Node", ...]:
        return ()


@dataclass(slots=True)
class Lit(Node):
    value: Value


@dataclass(slots=True)
class Col(Node):
    """Column reference, optionally qualified (``qual.name``). Lower-cased."""

    qual: str | None
    name: str


@dataclass(slots=True)
class Neg(Node):
    operand: Node

    def children(self):
        return (self.operand,)


@dataclass(slots=True)
class Not(Node):
    operand: Node

    def children(self):
        return (self.operand,)


@dataclass(slots=True)
class Bin(Node):
    """Binary operator: ``+ - * / %``, ``= != < <= > >=``, ``AND``, ``OR``."""

    op: str
    left: Node
    right: Node

    def children(self):
        return (self.left, self.right)


@dataclass(slots=True)
class IsNull(Node):
    operand: Node
    negated: bool

    def children(self):
        return (self.operand,)


@dataclass(slots=True)
class Like(Node):
    operand: Node
    pattern: Node
    negated: bool

    def children(self):
        return (self.operand, self.pattern)


@dataclass(slots=True)
class Agg(Node):
    """Aggregate call; ``arg`` is None for ``COUNT(*)``."""

    func: str
    arg: Node | None

    def children(self):
        return () if self.arg is None else (self.arg,)


def walk(node: Node) -> Iterator[Node]:
    """Yield ``node`` and all its descendants."""
    stack = [node]
    while stack:
        n = stack.pop()
        yield n
        stack.extend(n.children())


def contains_aggregate(node: Node) -> bool:
    return any(type(n) is Agg for n in walk(node))


# ---------------------------------------------------------------- statements


@dataclass(slots=True)
class CreateTable:
    name: str
    columns: list[str]


@dataclass(slots=True)
class Insert:
    table: str
    rows: list[list[Node]]


@dataclass(slots=True)
class Delete:
    table: str
    where: Node | None


@dataclass(slots=True)
class Update:
    table: str
    assignments: list[tuple[str, Node]]
    where: Node | None


@dataclass(slots=True)
class Star:
    """The ``*`` select item."""


@dataclass(slots=True)
class SelectItem:
    expr: Node
    alias: str | None


@dataclass(slots=True)
class TableRef:
    name: str
    alias: str | None

    @property
    def effective_name(self) -> str:
        return self.alias or self.name


@dataclass(slots=True)
class OrderTerm:
    """One ORDER BY term.

    ``ordinal`` is set when the term is a bare integer literal, ``alias`` when
    it is a single bare identifier (which may name a select-item alias).
    """

    expr: Node
    descending: bool
    ordinal: int | None = None
    alias: str | None = None


@dataclass(slots=True)
class Select:
    items: list[SelectItem | Star]
    tables: list[TableRef] = field(default_factory=list)
    on: Node | None = None
    where: Node | None = None
    group_by: list[Col] = field(default_factory=list)
    having: Node | None = None
    order_by: list[OrderTerm] = field(default_factory=list)
    limit: int | None = None
    offset: int | None = None


Statement = CreateTable | Insert | Delete | Update | Select
