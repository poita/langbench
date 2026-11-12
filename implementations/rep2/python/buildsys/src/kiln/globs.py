"""Glob patterns: compilation and matching.

A pattern is split on ``/`` into components.  ``**`` (exactly) matches zero or
more whole candidate components; every other component matches exactly one
candidate component and is a sequence of items: ``*``, ``?``, a character
class, or a literal byte.  Matching is O(pattern x candidate): a star
backtracking matcher is used both inside a component and across components.
"""

from __future__ import annotations

from functools import lru_cache

__all__ = ["Glob", "GlobSyntaxError", "compile_glob"]

_LIT, _ANY, _CLASS, _STAR = 0, 1, 2, 3


class GlobSyntaxError(ValueError):
    """The pattern is malformed (empty, bad component, bad character class)."""


def _parse_class(comp: bytes, i: int) -> tuple[bytes, int]:
    """Parse the class whose items start at ``comp[i]`` (just after ``[``)."""
    negate = False
    if i < len(comp) and comp[i] == 0x21:  # '!'
        negate = True
        i += 1
    table = bytearray(256)
    n = len(comp)
    items = 0
    while True:
        if i >= n:
            raise GlobSyntaxError("unterminated class")
        c = comp[i]
        if c == 0x5D:  # ']'
            if items == 0:
                raise GlobSyntaxError("empty class")
            i += 1
            break
        if i + 2 < n and comp[i + 1] == 0x2D and comp[i + 2] != 0x5D:
            lo, hi = c, comp[i + 2]
            if lo > hi:
                raise GlobSyntaxError("reversed range")
            for b in range(lo, hi + 1):
                table[b] = 1
            i += 3
        else:
            table[c] = 1
            i += 1
        items += 1
    if negate:
        table = bytearray(1 - v for v in table)
    return bytes(table), i


class _Component:
    """One non-``**`` pattern component."""

    __slots__ = ("items", "literal", "prefix", "suffix", "star_only")

    def __init__(self, items: list[tuple[int, object]]) -> None:
        self.items = tuple(items)
        self.literal: bytes | None = None
        self.prefix: bytes | None = None
        self.suffix: bytes | None = None
        self.star_only = len(items) == 1 and items[0][0] == _STAR
        if all(k == _LIT for k, _ in items):
            self.literal = bytes(d for _, d in items)  # type: ignore[misc]
        elif items[-1][0] == _STAR and all(k == _LIT for k, _ in items[:-1]):
            self.prefix = bytes(d for _, d in items[:-1])  # type: ignore[misc]
        elif items[0][0] == _STAR and all(k == _LIT for k, _ in items[1:]):
            self.suffix = bytes(d for _, d in items[1:])  # type: ignore[misc]

    def match(self, s: bytes) -> bool:
        if self.literal is not None:
            return s == self.literal
        if self.star_only:
            return True
        if self.prefix is not None:
            return s.startswith(self.prefix)
        if self.suffix is not None:
            return s.endswith(self.suffix)
        items = self.items
        n = len(items)
        m = len(s)
        i = j = 0
        star_i = -1
        star_j = 0
        while j < m:
            if i < n:
                kind, data = items[i]
                if kind == _STAR:
                    star_i = i
                    star_j = j
                    i += 1
                    continue
                if kind == _LIT:
                    ok = s[j] == data
                elif kind == _ANY:
                    ok = True
                else:
                    ok = data[s[j]] == 1  # type: ignore[index]
                if ok:
                    i += 1
                    j += 1
                    continue
            if star_i >= 0:
                star_j += 1
                j = star_j
                i = star_i + 1
                continue
            return False
        while i < n and items[i][0] == _STAR:
            i += 1
        return i == n


def _compile_component(comp: bytes) -> _Component:
    items: list[tuple[int, object]] = []
    i = 0
    n = len(comp)
    while i < n:
        c = comp[i]
        if c == 0x2A:  # '*'
            if not items or items[-1][0] != _STAR:
                items.append((_STAR, None))
            i += 1
        elif c == 0x3F:  # '?'
            items.append((_ANY, None))
            i += 1
        elif c == 0x5B:  # '['
            table, i = _parse_class(comp, i + 1)
            items.append((_CLASS, table))
        else:
            items.append((_LIT, c))
            i += 1
    return _Component(items)


class Glob:
    """A compiled glob pattern."""

    __slots__ = ("pattern", "parts", "literal_prefix")

    def __init__(self, pattern: bytes) -> None:
        comps = pattern.split(b"/")
        if any(c == b"" for c in comps):
            raise GlobSyntaxError("empty component")
        self.pattern = pattern
        #: ``None`` stands for a ``**`` component.
        self.parts: list[_Component | None] = [
            None if c == b"**" else _compile_component(c) for c in comps
        ]
        cut = len(pattern)
        for k, b in enumerate(pattern):
            if b in b"*?[":
                cut = k
                break
        prefix = pattern[:cut]
        # ``src/**`` matches ``src`` itself, so a trailing separator is not
        # part of the guaranteed prefix.
        if prefix.endswith(b"/"):
            prefix = prefix[:-1]
        #: Every matching candidate starts with this byte string.
        self.literal_prefix = prefix

    def match(self, candidate: bytes) -> bool:
        """True if the whole ``candidate`` string matches the pattern."""
        parts = self.parts
        comps = candidate.split(b"/")
        np_ = len(parts)
        nc = len(comps)
        pi = ci = 0
        star_p = -1
        star_c = 0
        while ci < nc:
            if pi < np_:
                part = parts[pi]
                if part is None:
                    star_p = pi
                    star_c = ci
                    pi += 1
                    continue
                if part.match(comps[ci]):
                    pi += 1
                    ci += 1
                    continue
            if star_p >= 0:
                star_c += 1
                ci = star_c
                pi = star_p + 1
                continue
            return False
        while pi < np_ and parts[pi] is None:
            pi += 1
        return pi == np_


@lru_cache(maxsize=4096)
def compile_glob(pattern: bytes) -> Glob:
    """Compile ``pattern``; raise :class:`GlobSyntaxError` if malformed."""
    return Glob(pattern)
