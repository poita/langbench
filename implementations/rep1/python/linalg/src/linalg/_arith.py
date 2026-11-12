"""Small arithmetic kernels shared by the algorithms.

The specification fixes the order of every floating-point sum, and Python's
built-in :func:`sum` uses compensated summation for floats, so sums are
always taken with :func:`functools.reduce` over ``operator.add``: one plain
running sum, in index order.
"""

from __future__ import annotations

from collections.abc import Iterable, Sequence
from functools import reduce
from operator import add, mul


def running_sum(values: Iterable[float]) -> float:
    """Sum ``values`` left to right in one running double-precision sum."""
    return reduce(add, values, 0.0)


def dot(x: Sequence[float], y: Sequence[float]) -> float:
    """Return ``sum(x[i] * y[i])`` accumulated over increasing ``i``."""
    return reduce(add, map(mul, x, y), 0.0)


def sum_squares(x: Sequence[float]) -> float:
    """Return ``sum(x[i] ** 2)`` accumulated over increasing ``i``."""
    return reduce(add, map(mul, x, x), 0.0)


def rotate(
    x: Sequence[float], y: Sequence[float], c: float, s: float
) -> tuple[list[float], list[float]]:
    """Apply a plane rotation to two vectors.

    Returns ``(c*x - s*y, s*x + c*y)`` elementwise.
    """
    return (
        [c * a - s * b for a, b in zip(x, y)],
        [s * a + c * b for a, b in zip(x, y)],
    )


def jacobi_tangent(theta: float) -> float:
    """Return the smaller root ``t`` of ``t**2 + 2*theta*t - 1 = 0``."""
    from math import sqrt

    if theta >= 0.0:
        return 1.0 / (theta + sqrt(theta * theta + 1.0))
    return -1.0 / (-theta + sqrt(theta * theta + 1.0))
