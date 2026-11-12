"""KBL glob patterns.

``compile_pattern`` validates a pattern and returns a :class:`Pattern`;
``Pattern.match`` tests a whole candidate string.  A pattern is a ``/``-separated
list of components: ``**`` (zero or more whole components) or a sequence of
literal bytes, ``*``, ``?`` and ``[...]`` classes.

Matching one candidate against a pattern is O(pattern x candidate): ``**``
segments are handled by a set-of-states walk over candidate components and each
component by the linear-backtracking wildcard algorithm.
"""

from __future__ import annotations

_STAR = -1
_ANY = -2
_META = b"*?["


class MalformedPattern(ValueError):
    """The glob pattern is not valid."""


class _Component:
    """One non-``**`` pattern component."""

    __slots__ = ("items", "literal")

    def __init__(self, items: list[int | bytes], literal: bytes | None) -> None:
        self.items = items
        self.literal = literal

    def match(self, s: bytes) -> bool:
        if self.literal is not None:
            return s == self.literal
        items = self.items
        ni = len(items)
        ns = len(s)
        i = j = 0
        star = -1
        mark = 0
        while j < ns:
            if i < ni:
                it = items[i]
                if type(it) is int:
                    if it == _STAR:
                        star = i
                        mark = j
                        i += 1
                        continue
                    if it == _ANY or it == s[j]:
                        i += 1
                        j += 1
                        continue
                elif it[s[j]]:  # character-class table
                    i += 1
                    j += 1
                    continue
            if star >= 0:
                mark += 1
                j = mark
                i = star + 1
                continue
            return False
        while i < ni and type(items[i]) is int and items[i] == _STAR:
            i += 1
        return i == ni


def _compile_component(comp: bytes) -> _Component:
    items: list[int | bytes] = []
    n = len(comp)
    i = 0
    while i < n:
        c = comp[i]
        if c == 0x2A:  # *
            if not items or items[-1] != _STAR:
                items.append(_STAR)
            i += 1
        elif c == 0x3F:  # ?
            items.append(_ANY)
            i += 1
        elif c == 0x5B:  # [
            i += 1
            negate = False
            if i < n and comp[i] == 0x21:
                negate = True
                i += 1
            members = bytearray(256)
            collected = 0
            while True:
                if i >= n:
                    raise MalformedPattern("unterminated class")
                c = comp[i]
                if c == 0x5D:  # ]
                    if not collected:
                        raise MalformedPattern("empty class")
                    i += 1
                    break
                if i + 2 < n and comp[i + 1] == 0x2D and comp[i + 2] != 0x5D:
                    lo, hi = c, comp[i + 2]
                    if lo > hi:
                        raise MalformedPattern("reversed range")
                    for b in range(lo, hi + 1):
                        members[b] = 1
                    i += 3
                else:
                    members[c] = 1
                    i += 1
                collected += 1
            if negate:
                members = bytearray(1 - m for m in members)
            items.append(bytes(members))
        else:
            items.append(c)
            i += 1
    literal = None
    if all(type(it) is int and it >= 0 for it in items):
        literal = bytes(items)  # type: ignore[arg-type]
    return _Component(items, literal)


class Pattern:
    """A compiled glob pattern."""

    __slots__ = ("source", "_parts", "prefix")

    def __init__(self, source: bytes, parts: list[_Component | None], prefix: bytes) -> None:
        self.source = source
        self._parts = parts  # ``None`` stands for a ``**`` component
        #: Every match starts with this wildcard-free prefix.
        self.prefix = prefix

    def match(self, candidate: bytes) -> bool:
        """True when the whole *candidate* matches."""
        parts = self._parts
        np_ = len(parts)
        states = self._closure({0})
        for comp in candidate.split(b"/"):
            nxt: set[int] = set()
            for i in states:
                if i < np_:
                    part = parts[i]
                    if part is None:
                        nxt.add(i)
                    elif part.match(comp):
                        nxt.add(i + 1)
            if not nxt:
                return False
            states = self._closure(nxt)
        return np_ in states

    def _closure(self, states: set[int]) -> set[int]:
        parts = self._parts
        np_ = len(parts)
        out = set(states)
        for i in states:
            while i < np_ and parts[i] is None:
                i += 1
                out.add(i)
        return out

    def __repr__(self) -> str:
        return f"Pattern({self.source!r})"


def _literal_prefix(raw: list[bytes]) -> bytes:
    lits: list[bytes] = []
    for comp in raw:
        if comp == b"**":
            return b"/".join(lits)
        cut = len(comp)
        for k, c in enumerate(comp):
            if c in _META:
                cut = k
                break
        if cut == len(comp):
            lits.append(comp)
            continue
        lits.append(comp[:cut])
        return b"/".join(lits)
    return b"/".join(lits)


def compile_pattern(source: bytes) -> Pattern:
    """Compile *source*; raises :class:`MalformedPattern` when invalid."""
    raw = source.split(b"/")
    if any(not comp for comp in raw):
        raise MalformedPattern("empty component")
    parts: list[_Component | None] = []
    for comp in raw:
        parts.append(None if comp == b"**" else _compile_component(comp))
    return Pattern(source, parts, _literal_prefix(raw))
