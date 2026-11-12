"""Matrix norms, each with the summation order the specification fixes."""

from __future__ import annotations

from itertools import chain
from math import sqrt

from ._arith import running_sum, sum_squares
from .matrix import Matrix


def norm1(a: Matrix) -> float:
    """Maximum absolute column sum (each column summed over increasing row)."""
    return max(running_sum(map(abs, col)) for col in zip(*a.iter_rows()))


def norminf(a: Matrix) -> float:
    """Maximum absolute row sum (each row summed over increasing column)."""
    return max(running_sum(map(abs, row)) for row in a.iter_rows())


def normfro(a: Matrix) -> float:
    """Frobenius norm: one running sum of squares in row-major order."""
    return sqrt(sum_squares(list(chain.from_iterable(a.iter_rows()))))
