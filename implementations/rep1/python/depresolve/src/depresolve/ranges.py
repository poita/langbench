"""Version ranges, normalised to half-open intervals of version keys."""

from __future__ import annotations

from dataclasses import dataclass

from .version import KEY_LIMIT, Version

_COMPARATORS = ("<=", ">=", "<", ">")


@dataclass(frozen=True, slots=True)
class VersionRange:
    """The set of versions ``v`` with ``low <= v.key < high``.

    Every range of the input grammar (``*``, exact, caret, tilde and
    comparator lists) is expressible this way. An empty interval
    (``low >= high``) accepts nothing.
    """

    low: int = 0
    high: int = KEY_LIMIT

    def contains(self, version: Version) -> bool:
        """Return whether *version* satisfies this range."""
        return self.low <= version.key < self.high

    def __contains__(self, version: object) -> bool:
        return isinstance(version, Version) and self.contains(version)

    def intersect(self, other: VersionRange) -> VersionRange:
        """Return the range accepted by both ``self`` and *other*."""
        return VersionRange(max(self.low, other.low), min(self.high, other.high))

    @property
    def is_empty(self) -> bool:
        return self.low >= self.high

    @classmethod
    def parse(cls, text: str) -> VersionRange:
        """Parse a range such as ``*``, ``1.2.3``, ``^1.2.3``, ``~1.2.3`` or
        ``>=1.0.0 <2.0.0``. Raises :class:`ValueError` on malformed text."""
        if text == "*":
            return cls()
        if text[:1] == "^":
            return _caret(Version.parse(text[1:]))
        if text[:1] == "~":
            v = Version.parse(text[1:])
            return cls(v.key, Version(v.major, v.minor + 1, 0).key)
        if text[:1] in "<>":
            result = cls()
            for token in text.split(" "):
                result = result.intersect(_comparator(token))
            return result
        v = Version.parse(text)
        return cls(v.key, v.key + 1)


def _caret(v: Version) -> VersionRange:
    """``^`` keeps the leftmost non-zero component fixed."""
    if v.major > 0:
        upper = Version(v.major + 1, 0, 0)
    elif v.minor > 0:
        upper = Version(0, v.minor + 1, 0)
    else:
        upper = Version(0, 0, v.patch + 1)
    return VersionRange(v.key, upper.key)


def _comparator(token: str) -> VersionRange:
    for op in _COMPARATORS:
        if token.startswith(op):
            key = Version.parse(token[len(op):]).key
            break
    else:
        raise ValueError(f"invalid comparator: {token!r}")
    if op == "<":
        return VersionRange(0, key)
    if op == "<=":
        return VersionRange(0, key + 1)
    if op == ">":
        return VersionRange(key + 1, KEY_LIMIT)
    return VersionRange(key, KEY_LIMIT)
