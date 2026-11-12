"""Static analysis used to cut down the start positions that must be tried."""

from __future__ import annotations

from .ast import (Alt, Any, Bol, Char, CharSet, Eol, Group, Node,
                  Repeat, Seq)


def _union(a, b):
    return None if a is None or b is None else a | b


def first_set(node: Node) -> tuple[frozenset[str] | None, bool]:
    """Return ``(first, nullable)`` for ``node``.

    ``first`` is a superset of the characters a match of ``node`` can begin
    with, or ``None`` when any character may begin a match. ``nullable`` is true when ``node`` might match without consuming
    anything (anchors are treated as transparent, so this is conservative).
    """
    if isinstance(node, Char):
        return frozenset(node.char), False
    if isinstance(node, Any):
        return None, False
    if isinstance(node, CharSet):
        return node.chars, False
    if isinstance(node, (Bol, Eol)):
        return frozenset(), True
    if isinstance(node, Group):
        return first_set(node.child)
    if isinstance(node, Repeat):
        if node.max == 0:
            return frozenset(), True
        chars, nullable = first_set(node.child)
        return chars, nullable or node.min == 0
    if isinstance(node, Seq):
        chars = frozenset()
        for item in node.items:
            c, nullable = first_set(item)
            chars = _union(chars, c)
            if not nullable:
                return chars, False
        return chars, True
    if isinstance(node, Alt):
        chars = frozenset()
        nullable = False
        for b in node.branches:
            c, n = first_set(b)
            chars = _union(chars, c)
            nullable = nullable or n
        return chars, nullable
    raise TypeError(node)  # pragma: no cover


def anchored_start(node: Node) -> bool:
    """True if every match of ``node`` must begin at subject position 0."""
    if isinstance(node, Bol):
        return True
    if isinstance(node, Group):
        return anchored_start(node.child)
    if isinstance(node, Repeat):
        return node.min >= 1 and anchored_start(node.child)
    if isinstance(node, Seq):
        return any(anchored_start(i) for i in node.items)
    if isinstance(node, Alt):
        return all(anchored_start(b) for b in node.branches)
    return False
