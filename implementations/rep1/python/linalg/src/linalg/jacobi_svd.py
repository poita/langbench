"""Singular value decomposition by one-sided Jacobi rotations, and ``cond``."""

from __future__ import annotations

from math import sqrt

from ._arith import dot, jacobi_tangent, rotate, sum_squares
from .errors import Singular
from .matrix import Matrix
from .signs import needs_flip

MAX_SWEEPS = 60
TOLERANCE = 1e-14


def _jacobi_tall(cols: list[list[float]]) -> tuple[list[list[float]], list[float], list[list[float]]]:
    """One-sided Jacobi on the columns ``W`` of an ``m' x n'`` matrix, ``m' >= n'``.

    Returns ``(left columns, singular values, right columns)`` sorted by
    descending singular value.
    """
    n = len(cols)
    w = cols
    v = [[1.0 if i == j else 0.0 for i in range(n)] for j in range(n)]
    for _ in range(MAX_SWEEPS):
        rotated = False
        for p in range(n - 1):
            for q in range(p + 1, n):
                wp = w[p]
                wq = w[q]
                alpha = sum_squares(wp)
                beta = sum_squares(wq)
                gamma = dot(wp, wq)
                if gamma == 0.0 or alpha == 0.0 or beta == 0.0:
                    continue
                if abs(gamma) <= TOLERANCE * sqrt(alpha * beta):
                    continue
                zeta = (beta - alpha) / (2.0 * gamma)
                t = jacobi_tangent(zeta)
                c = 1.0 / sqrt(t * t + 1.0)
                s = t * c
                w[p], w[q] = rotate(wp, wq, c, s)
                v[p], v[q] = rotate(v[p], v[q], c, s)
                rotated = True
        if not rotated:
            break
    sigma = [sqrt(sum_squares(col)) for col in w]
    order = sorted(range(n), key=lambda j: -sigma[j])  # stable on ties
    left = []
    for j in order:
        s = sigma[j]
        left.append([x / s for x in w[j]] if s != 0.0 else [0.0] * len(w[j]))
    return left, [sigma[j] for j in order], [v[j] for j in order]


def svd(a: Matrix) -> tuple[Matrix, list[float], Matrix]:
    """Thin SVD ``A = U diag(s) Vᵀ`` of an ``m x n`` matrix.

    With ``k = min(m, n)``: ``U`` is ``m x k``, ``s`` has ``k`` descending
    non-negative entries and ``V`` is ``n x k``.  Each column of ``U`` is
    sign-normalised (largest-magnitude entry positive) and the matching
    column of ``V`` is negated with it.
    """
    m, n = a.shape
    if m >= n:
        u_cols, sigma, v_cols = _jacobi_tall(a.to_columns())
    else:
        # Work on Aᵀ, whose columns are the rows of A; the factors swap roles.
        v_cols, sigma, u_cols = _jacobi_tall(a.to_rows())
    for j in range(len(sigma)):
        if needs_flip(u_cols[j]):
            u_cols[j] = [-x for x in u_cols[j]]
            v_cols[j] = [-x for x in v_cols[j]]
    return Matrix.from_columns(u_cols), sigma, Matrix.from_columns(v_cols)


def singular_values(a: Matrix) -> list[float]:
    """The singular values of ``A``, descending."""
    return svd(a)[1]


def cond(a: Matrix) -> float:
    """2-norm condition number ``σ_max / σ_min``.

    Raises :class:`Singular` if the smallest singular value is exactly zero.
    """
    sigma = singular_values(a)
    if sigma[-1] == 0.0:
        raise Singular()
    return sigma[0] / sigma[-1]
