"""Syntax tree for formulas.

Trees are built once by :mod:`spreadsheet.parser` and walked by
:mod:`spreadsheet.evaluator`.  References are already resolved to cell keys.
"""

from __future__ import annotations

from dataclasses import dataclass

from .values import Value

__all__ = [
    "Literal",
    "Ref",
    "Range",
    "Neg",
    "Arith",
    "Concat",
    "Compare",
    "If",
    "Aggregate",
    "Node",
]


@dataclass(frozen=True, slots=True)
class Literal:
    """A constant: a number, a string or (for bad references) an error."""

    value: Value


@dataclass(frozen=True, slots=True)
class Ref:
    key: int


@dataclass(frozen=True, slots=True)
class Range:
    """Rectangle ``row1..row2`` x ``col1..col2`` (already normalised)."""

    row1: int
    col1: int
    row2: int
    col2: int


@dataclass(frozen=True, slots=True)
class Neg:
    operand: "Node"


@dataclass(frozen=True, slots=True)
class Arith:
    op: str  # one of + - * /
    left: "Node"
    right: "Node"


@dataclass(frozen=True, slots=True)
class Concat:
    left: "Node"
    right: "Node"


@dataclass(frozen=True, slots=True)
class Compare:
    op: str  # one of = <> < > <= >=
    left: "Node"
    right: "Node"


@dataclass(frozen=True, slots=True)
class If:
    cond: "Node"
    then: "Node"
    otherwise: "Node"


@dataclass(frozen=True, slots=True)
class Aggregate:
    func: str  # SUM MIN MAX AVG COUNT
    args: tuple["Node", ...]  # expressions or Range nodes


Node = Literal | Ref | Range | Neg | Arith | Concat | Compare | If | Aggregate
