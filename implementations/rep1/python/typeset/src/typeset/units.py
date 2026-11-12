"""Exact integer arithmetic and small number-formatting helpers."""

from __future__ import annotations

import re

#: Millipoints per unit for the length suffixes.
UNIT_MP = {"": 1, "pt": 1000, "mm": 2835, "cm": 28350, "in": 72000, "pc": 12000}

_LENGTH_RE = re.compile(r"(-?)([0-9]+)(?:\.([0-9]{1,3}))?(pt|mm|cm|in|pc)?\Z")
_INTEGER_RE = re.compile(r"-?[0-9]+\Z")


def fdiv(a: int, b: int) -> int:
    """Floor division (``b > 0``); Python's ``//`` already floors."""
    return a // b


def scale(units: int, size: int) -> int:
    """Scale glyph-space *units* (1/1000 em) to millipoints at *size*."""
    return (units * size) // 1000


def parse_length(text: str) -> int | None:
    """Parse a length literal to millipoints, or return ``None`` if invalid."""
    m = _LENGTH_RE.match(text)
    if m is None:
        return None
    neg, whole, frac, unit = m.groups()
    k = len(frac) if frac else 0
    fval = int(frac) if frac else 0
    value = ((int(whole) * 10**k + fval) * UNIT_MP[unit or ""]) // 10**k
    return -value if neg else value


def parse_integer(text: str) -> int | None:
    """Parse ``[-]DIGITS`` or return ``None``."""
    if _INTEGER_RE.match(text) is None:
        return None
    return int(text)


_ROMAN = (
    (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
    (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
)


def roman(n: int) -> str:
    """Lowercase roman numeral by greedy subtraction (unbounded above 3999)."""
    out = []
    for value, sym in _ROMAN:
        q, n = divmod(n, value)
        out.append(sym * q)
    return "".join(out)


def alpha(n: int) -> str:
    """Bijective base-26 lowercase letters: 1 -> a, 26 -> z, 27 -> aa."""
    out = []
    while n > 0:
        n, r = divmod(n - 1, 26)
        out.append(chr(97 + r))
    return "".join(reversed(out))


def distribute(total: int, weights: list[int]) -> list[int]:
    """Split *total* over *weights* proportionally with floor-cumulative rounding.

    Returns the increment for each weight; the increments sum to *total*.
    ``sum(weights)`` must be positive.
    """
    t = sum(weights)
    out = []
    p = 0
    prev = 0
    for w in weights:
        p += w
        c = (total * p) // t
        out.append(c - prev)
        prev = c
    return out
