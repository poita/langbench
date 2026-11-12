"""Syntax tree for the supported jq subset."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Optional, Tuple


class Node:
    __slots__ = ()


@dataclass(frozen=True, slots=True)
class Identity(Node):
    pass


@dataclass(frozen=True, slots=True)
class Literal(Node):
    value: Any


@dataclass(frozen=True, slots=True)
class Var(Node):
    name: str


@dataclass(frozen=True, slots=True)
class Index(Node):
    """``term[key]`` / ``term.name``; ``opt`` makes just this operation tolerant."""

    term: Node
    key: Node
    opt: bool = False


@dataclass(frozen=True, slots=True)
class Slice(Node):
    term: Node
    lo: Optional[Node]
    hi: Optional[Node]
    opt: bool = False


@dataclass(frozen=True, slots=True)
class Iterate(Node):
    term: Node
    opt: bool = False


@dataclass(frozen=True, slots=True)
class Try(Node):
    body: Node


@dataclass(frozen=True, slots=True)
class Pipe(Node):
    left: Node
    right: Node


@dataclass(frozen=True, slots=True)
class Comma(Node):
    left: Node
    right: Node


@dataclass(frozen=True, slots=True)
class BinOp(Node):
    op: str  # + - * / % == != < <= > >=
    left: Node
    right: Node


@dataclass(frozen=True, slots=True)
class And(Node):
    left: Node
    right: Node


@dataclass(frozen=True, slots=True)
class Or(Node):
    left: Node
    right: Node


@dataclass(frozen=True, slots=True)
class Neg(Node):
    operand: Node


@dataclass(frozen=True, slots=True)
class ArrayCons(Node):
    body: Optional[Node]


@dataclass(frozen=True, slots=True)
class ObjectCons(Node):
    entries: Tuple[Tuple[Node, Node], ...]  # (key expression, value expression)


@dataclass(frozen=True, slots=True)
class If(Node):
    cond: Node
    then: Node
    orelse: Optional[Node]  # None means "."


@dataclass(frozen=True, slots=True)
class As(Node):
    source: Node
    name: str
    body: Node


@dataclass(frozen=True, slots=True)
class Reduce(Node):
    source: Node
    name: str
    init: Node
    update: Node


@dataclass(frozen=True, slots=True)
class Call(Node):
    name: str
    args: Tuple[Node, ...]
