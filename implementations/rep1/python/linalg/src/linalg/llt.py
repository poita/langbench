"""Cholesky factorisation."""

from __future__ import annotations

from math import sqrt

from ._arith import dot, sum_squares
from .errors import NotPositiveDefinite, NotSquare, NotSymmetric
from .matrix import Matrix


def cholesky(a: Matrix) -> Matrix:
    """Lower-triangular ``L`` with ``A = L Lᵀ`` for symmetric positive definite ``A``.

    Raises :class:`NotSquare`, :class:`NotSymmetric` (exact comparison) or
    :class:`NotPositiveDefinite` (a pivot ``s <= 0``).
    """
    if not a.is_square:
        raise NotSquare(f"shape {a.shape}")
    if not a.is_symmetric():
        raise NotSymmetric()
    n = a.rows
    rows = a.to_rows()
    low = [[0.0] * n for _ in range(n)]
    for j in range(n):
        lj = low[j]
        head = lj[:j]
        s = rows[j][j] - sum_squares(head)
        if s <= 0.0:
            raise NotPositiveDefinite()
        d = sqrt(s)
        lj[j] = d
        for i in range(j + 1, n):
            li = low[i]
            li[j] = (rows[i][j] - dot(li[:j], head)) / d
    return Matrix(low)
