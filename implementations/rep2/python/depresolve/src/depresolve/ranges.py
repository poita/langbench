"""Version ranges, normalised to half-open intervals ``[lo, hi)``."""

from __future__ import annotations

from dataclasses import dataclass

from .version import Version

_ZERO = Version(0, 0, 0)


@dataclass(frozen=True, slots=True)
class Range:
    """The versions ``v`` with ``lo <= v < hi`` (``hi is None``: unbounded)."""

    lo: Version = _ZERO
    hi: Version | None = None

    def __contains__(self, version: Version) -> bool:
        return self.lo <= version and (self.hi is None or version < self.hi)

    def is_empty(self) -> bool:
        """True when no version can satisfy the range."""
        return self.hi is not None and self.hi <= self.lo

    def intersect(self, other: Range) -> Range:
        """The range accepting exactly the versions both ranges accept."""
        lo = max(self.lo, other.lo)
        if self.hi is None:
            hi = other.hi
        elif other.hi is None:
            hi = self.hi
        else:
            hi = min(self.hi, other.hi)
        return Range(lo, hi)


def parse_range(text: str) -> Range:
    """Parse a range expression.

    Supported forms: ``*``, ``X.Y.Z`` (exact), ``^X.Y.Z``, ``~X.Y.Z`` and one
    or more space-separated comparators (``<``, ``<=``, ``>``, ``>=``), all of
    which must hold.  Caret and tilde follow npm semantics.
    """
    if text == "*":
        return Range()
    head = text[0]
    if head == "^":
        v = Version.parse(text[1:])
        if v.major > 0:
            hi = Version(v.major + 1, 0, 0)
        elif v.minor > 0:
            hi = Version(0, v.minor + 1, 0)
        else:
            hi = Version(0, 0, v.patch + 1)
        return Range(v, hi)
    if head == "~":
        v = Version.parse(text[1:])
        return Range(v, Version(v.major, v.minor + 1, 0))
    if head.isdigit():
        v = Version.parse(text)
        return Range(v, v.successor())
    result = Range()
    for token in text.split(" "):
        if token.startswith(">="):
            part = Range(Version.parse(token[2:]), None)
        elif token.startswith("<="):
            part = Range(_ZERO, Version.parse(token[2:]).successor())
        elif token.startswith(">"):
            part = Range(Version.parse(token[1:]).successor(), None)
        elif token.startswith("<"):
            part = Range(_ZERO, Version.parse(token[1:]))
        else:
            raise ValueError(f"bad comparator: {token!r}")
        result = result.intersect(part)
    return result
