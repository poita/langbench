"""Syntax-tree node types produced by :mod:`btregex.parser`.

Every node knows ``min_len``, the minimum number of characters it can consume.
The compiler uses it to decide whether a loop body can match the empty string.
"""

from __future__ import annotations

#: The alphabet over which class complements (``\D``, ``[^a]``, ...) are taken.
ASCII = frozenset(map(chr, range(128)))


class Node:
    __slots__ = ("min_len",)


class Char(Node):
    """A single literal character."""

    __slots__ = ("char",)

    def __init__(self, char: str) -> None:
        self.char = char
        self.min_len = 1


class Any(Node):
    """``.`` -- any single character."""

    __slots__ = ()

    def __init__(self) -> None:
        self.min_len = 1


class CharSet(Node):
    """A character class, already resolved to the set of characters it accepts."""

    __slots__ = ("chars",)

    def __init__(self, chars: frozenset[str]) -> None:
        self.chars = chars
        self.min_len = 1


class Bol(Node):
    """``^`` -- matches only at position 0."""

    __slots__ = ()

    def __init__(self) -> None:
        self.min_len = 0


class Eol(Node):
    """``$`` -- matches only at the end of the subject."""

    __slots__ = ()

    def __init__(self) -> None:
        self.min_len = 0


class Seq(Node):
    """Concatenation; an empty sequence matches the empty string."""

    __slots__ = ("items",)

    def __init__(self, items: list[Node]) -> None:
        self.items = items
        self.min_len = sum(i.min_len for i in items)


class Alt(Node):
    """Ordered choice between branches (leftmost branch preferred)."""

    __slots__ = ("branches",)

    def __init__(self, branches: list[Node]) -> None:
        self.branches = branches
        self.min_len = min(b.min_len for b in branches)


class Group(Node):
    """A capturing group; ``index`` is 1-based, by position of its ``(``."""

    __slots__ = ("index", "child")

    def __init__(self, index: int, child: Node) -> None:
        self.index = index
        self.child = child
        self.min_len = child.min_len


class Repeat(Node):
    """Greedy repetition ``child{min,max}``; ``max`` is ``None`` for no limit."""

    __slots__ = ("child", "min", "max")

    def __init__(self, child: Node, min: int, max: int | None) -> None:
        self.child = child
        self.min = min
        self.max = max
        self.min_len = child.min_len * min
