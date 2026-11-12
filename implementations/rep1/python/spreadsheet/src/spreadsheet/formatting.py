"""Number formatting (the spec's *Display* rules)."""

from __future__ import annotations

__all__ = ["format_number"]

_INTEGER_LIMIT = 1e15


def format_number(v: float) -> str:
    """Display a finite number.

    Zero is ``0``; integral values below 1e15 print as plain integers; any
    other value prints like C's ``printf("%.10g")``.  Python's ``%`` operator
    rounds the exact binary value half-to-even and uses the C exponent rules,
    so it matches the specification exactly.
    """
    if v == 0:
        return "0"
    if v.is_integer() and abs(v) < _INTEGER_LIMIT:
        return str(int(v))
    return "%.10g" % v
