"""Static analysis used to decide which start positions are worth trying."""

from __future__ import annotations

from .nodes import (
    AnyChar,
    Alternation,
    CharClass,
    EndAnchor,
    Group,
    Literal,
    Node,
    Repeat,
    Sequence,
    StartAnchor,
)

_EMPTY: frozenset[str] = frozenset()


def first_chars(node: Node) -> tuple[frozenset[str] | None, bool]:
    """Return ``(chars, nullable)`` for ``node``.

    ``chars`` is the set of characters a match of ``node`` can start with, or
    ``None`` if it may start with any character. ``nullable`` is true when
    ``node`` can match without consuming anything (assertions count as
    nullable, which is conservative).
    """
    if isinstance(node, Literal):
        return frozenset(node.char), False
    if isinstance(node, AnyChar):
        return None, False
    if isinstance(node, CharClass):
        return node.chars, False
    if isinstance(node, (StartAnchor, EndAnchor)):
        return _EMPTY, True
    if isinstance(node, Group):
        return first_chars(node.body)
    if isinstance(node, Alternation):
        chars: frozenset[str] | None = _EMPTY
        nullable = False
        for branch in node.branches:
            c, n = first_chars(branch)
            chars = _union(chars, c)
            nullable = nullable or n
        return chars, nullable
    if isinstance(node, Sequence):
        chars = _EMPTY
        for item in node.items:
            c, n = first_chars(item)
            chars = _union(chars, c)
            if not n:
                return chars, False
        return chars, True
    if isinstance(node, Repeat):
        if node.max == 0:
            return _EMPTY, True
        c, n = first_chars(node.body)
        return c, n or node.min == 0
    raise TypeError(f"unknown node {node!r}")


def _union(a: frozenset[str] | None, b: frozenset[str] | None) -> frozenset[str] | None:
    if a is None or b is None:
        return None
    return a | b


def is_start_anchored(node: Node) -> bool:
    """True if every match of ``node`` must begin at position 0."""
    if isinstance(node, StartAnchor):
        return True
    if isinstance(node, Group):
        return is_start_anchored(node.body)
    if isinstance(node, Alternation):
        return all(is_start_anchored(b) for b in node.branches)
    if isinstance(node, Sequence):
        # Positions never decrease, so one anchored item forces start == 0.
        return any(is_start_anchored(i) for i in node.items)
    if isinstance(node, Repeat):
        return node.min > 0 and is_start_anchored(node.body)
    return False
