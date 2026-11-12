"""Syntax-tree node types produced by :mod:`btregex.parser`."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Literal:
    """A single literal character."""

    char: str


@dataclass(frozen=True, slots=True)
class AnyChar:
    """``.`` -- any single character."""


@dataclass(frozen=True, slots=True)
class CharClass:
    """A character class, already resolved to the set of characters it matches.

    Negated classes and complement escapes (``\\D``, ``\\W``, ``\\S``) are
    resolved over the ASCII range at parse time, so matching is a plain set
    membership test.
    """

    chars: frozenset[str]


@dataclass(frozen=True, slots=True)
class StartAnchor:
    """``^`` -- matches only at position 0."""


@dataclass(frozen=True, slots=True)
class EndAnchor:
    """``$`` -- matches only at the end of the subject."""


@dataclass(frozen=True, slots=True)
class Group:
    """A capturing group. ``index`` is 1-based, in order of the opening ``(``."""

    index: int
    body: "Node"


@dataclass(frozen=True, slots=True)
class Alternation:
    """``a|b|c`` -- ordered choice between branches."""

    branches: tuple["Node", ...]


@dataclass(frozen=True, slots=True)
class Sequence:
    """Concatenation. An empty sequence matches the empty string."""

    items: tuple["Node", ...]


@dataclass(frozen=True, slots=True)
class Repeat:
    """A greedy counted quantifier; ``max`` is ``None`` for unbounded."""

    body: "Node"
    min: int
    max: int | None


Node = (
    Literal
    | AnyChar
    | CharClass
    | StartAnchor
    | EndAnchor
    | Group
    | Alternation
    | Sequence
    | Repeat
)
