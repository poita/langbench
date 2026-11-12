"""Symmetric eigendecomposition by cyclic Jacobi rotations."""

from __future__ import annotations

from itertools import chain
from math import inf, sqrt

from ._arith import jacobi_tangent, rotate, sum_squares
from .errors import NotSquare, NotSymmetric
from .matrix import Matrix
from .norms import normfro
from .signs import needs_flip

MAX_SWEEPS = 60
TOLERANCE = 1e-14


def _off(m: list[list[float]]) -> float:
    upper = chain.from_iterable(row[i + 1 :] for i, row in enumerate(m))
    return sqrt(2.0 * sum_squares(list(upper)))


def eigh(a: Matrix) -> tuple[list[float], Matrix]:
    """Eigen-decomposition ``A = V diag(w) Vᵀ`` of a symmetric matrix.

    Returns ``(w, V)`` with the eigenvalues ascending and each column of ``V``
    a unit eigenvector, sign-normalised (largest-magnitude entry positive).
    Raises :class:`NotSquare` or :class:`NotSymmetric`.
    """
    if not a.is_square:
        raise NotSquare(f"shape {a.shape}")
    if not a.is_symmetric():
        raise NotSymmetric()
    n = a.rows
    m = a.to_rows()
    v = [[1.0 if i == j else 0.0 for i in range(n)] for j in range(n)]  # columns
    phi = normfro(a)
    prev = inf
    for _ in range(MAX_SWEEPS):
        off = _off(m)
        if off <= TOLERANCE * phi or off >= prev:
            break
        prev = off
        for p in range(n - 1):
            for q in range(p + 1, n):
                apq = m[p][q]
                if apq == 0.0:
                    continue
                theta = (m[q][q] - m[p][p]) / (2.0 * apq)
                t = jacobi_tangent(theta)
                c = 1.0 / sqrt(t * t + 1.0)
                s = t * c
                for row in m:  # columns p, q
                    x = row[p]
                    y = row[q]
                    row[p] = c * x - s * y
                    row[q] = s * x + c * y
                m[p], m[q] = rotate(m[p], m[q], c, s)  # rows p, q
                m[p][q] = 0.0
                m[q][p] = 0.0
                v[p], v[q] = rotate(v[p], v[q], c, s)
    w = [m[i][i] for i in range(n)]
    order = sorted(range(n), key=lambda i: w[i])  # stable: ties keep original order
    columns = []
    for i in order:
        col = v[i]
        columns.append([-x for x in col] if needs_flip(col) else col)
    return [w[i] for i in order], Matrix.from_columns(columns)
