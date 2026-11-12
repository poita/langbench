"""Fixed-point float printing (SPEC section 14.3)."""

from __future__ import annotations

import math


def show_float_at(x: float, digits: int) -> str:
    """``showFloatAt`` without the digit-range check: exactly ``printf("%.*f")``."""
    if x != x:
        return "nan"
    if x == math.inf:
        return "inf"
    if x == -math.inf:
        return "-inf"
    return "%.*f" % (digits, x)
