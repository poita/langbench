"""SQL values: representation, ordering, truthiness and text rendering.

A value is one of ``None`` (NULL), ``int`` (INTEGER), ``str`` (TEXT) or
:class:`Real` (the result of ``AVG``; never stored in a table).
"""

from __future__ import annotations

from typing import Union


class Real:
    """A REAL value, held exactly as a whole number of hundredths."""

    __slots__ = ("hundredths",)

    def __init__(self, hundredths: int) -> None:
        self.hundredths = hundredths

    def __eq__(self, other: object) -> bool:
        return isinstance(other, Real) and self.hundredths == other.hundredths

    def __hash__(self) -> int:
        return hash(("Real", self.hundredths))

    def __repr__(self) -> str:
        return f"Real({format_real(self.hundredths)})"


Value = Union[None, int, str, Real]


def format_real(hundredths: int) -> str:
    """Render hundredths with exactly two decimals; zero never gets a sign."""
    sign = "-" if hundredths < 0 else ""
    mag = -hundredths if hundredths < 0 else hundredths
    return f"{sign}{mag // 100}.{mag % 100:02d}"


def format_value(value: Value) -> str:
    """Render a value the way SELECT output prints it."""
    if value is None:
        return "NULL"
    if type(value) is int:
        return str(value)
    if type(value) is str:
        return value
    return format_real(value.hundredths)


def average(total: int, count: int) -> Real:
    """``total / count`` rounded half away from zero to two decimals."""
    h = (200 * abs(total) + count) // (2 * count)
    return Real(-h if total < 0 else h)


def compare(a: Value, b: Value) -> int:
    """Three-way comparison implementing the engine's total order.

    NULL is smallest; every number is smaller than every text; numbers compare
    numerically (INTEGER against REAL by value); text compares by code point.
    Returns a negative number, zero or a positive number.
    """
    if a is None:
        return 0 if b is None else -1
    if b is None:
        return 1
    ta = type(a)
    tb = type(b)
    if ta is str:
        if tb is str:
            return (a > b) - (a < b)
        return 1
    if tb is str:
        return -1
    if ta is int and tb is int:
        return (a > b) - (a < b)
    x = a * 100 if ta is int else a.hundredths
    y = b * 100 if tb is int else b.hundredths
    return (x > y) - (x < y)


def truth(value: Value) -> bool | None:
    """Interpret a value in boolean context: True, False, or None (unknown).

    TEXT in boolean context is outside the specification; it is false here.
    """
    if value is None:
        return None
    t = type(value)
    if t is int:
        return value != 0
    if t is Real:
        return value.hundredths != 0
    return False


def to_text(value: Value) -> str:
    """Text form of a non-NULL value (used by LIKE on numbers)."""
    return format_value(value)
