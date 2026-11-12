"""Householder QR factorisation and linear least squares."""

from __future__ import annotations

from math import sqrt

from ._arith import dot, sum_squares
from ._triangular import back_upper
from .errors import DimensionMismatch, Singular
from .matrix import Matrix


def _householder(a: Matrix) -> tuple[list[list[float]], list[list[float]]]:
    """Return ``(Q columns, R columns)`` of the normalised thin QR of ``A``.

    ``Q`` has ``n`` columns of length ``m``; ``R`` has ``n`` columns of length
    ``m`` whose entries below the diagonal are exactly zero (only the first
    ``n`` rows are meaningful).
    """
    m, n = a.shape
    r = a.to_columns()
    reflectors: list[list[float]] = []
    for k in range(n):
        col = r[k]
        x = col[k:]
        nu = sqrt(sum_squares(x))
        if nu == 0.0:
            reflectors.append([])
            col[k + 1 :] = [0.0] * (m - k - 1)
            continue
        alpha = -nu if col[k] >= 0.0 else nu
        v = list(x)
        v[0] = v[0] - alpha
        length = sqrt(sum_squares(v))
        v = [t / length for t in v]
        reflectors.append(v)
        for j in range(k + 1, n):
            cj = r[j]
            tail = cj[k:]
            d = 2.0 * dot(v, tail)
            cj[k:] = [t - d * u for t, u in zip(tail, v)]
        col[k] = alpha
        col[k + 1 :] = [0.0] * (m - k - 1)

    q = [[1.0 if i == j else 0.0 for i in range(m)] for j in range(n)]
    for k in range(n - 1, -1, -1):
        v = reflectors[k]
        if not v:
            continue
        for qj in q:
            tail = qj[k:]
            d = 2.0 * dot(v, tail)
            qj[k:] = [t - d * u for t, u in zip(tail, v)]

    for j in range(n):
        if r[j][j] < 0.0:
            q[j] = [-t for t in q[j]]
            for c in range(j, n):
                r[c][j] = -r[c][j]
    return q, r


def qr(a: Matrix) -> tuple[Matrix, Matrix]:
    """Thin QR factorisation ``A = Q R`` of an ``m x n`` matrix, ``m >= n``.

    ``Q`` is ``m x n`` with orthonormal columns; ``R`` is ``n x n`` upper
    triangular with a non-negative diagonal.  Raises
    :class:`DimensionMismatch` if ``m < n``.
    """
    m, n = a.shape
    if m < n:
        raise DimensionMismatch(f"qr needs rows >= cols, got {a.shape}")
    q, r = _householder(a)
    q_matrix = Matrix.from_columns(q)
    r_matrix = Matrix([r[j][i] if j >= i else 0.0 for j in range(n)] for i in range(n))
    return q_matrix, r_matrix


def lstsq(a: Matrix, b: Matrix) -> Matrix:
    """Least-squares solution ``X`` minimising ``‖A X - B‖F`` (``A`` full column rank).

    Raises :class:`DimensionMismatch` if ``m < n`` or ``B`` has the wrong
    number of rows, and :class:`Singular` if ``R`` has an exactly-zero diagonal
    entry.
    """
    m, n = a.shape
    if m < n:
        raise DimensionMismatch(f"lstsq needs rows >= cols, got {a.shape}")
    if b.rows != m:
        raise DimensionMismatch(f"right-hand side has {b.rows} rows, expected {m}")
    q, r = _householder(a)
    if any(r[j][j] == 0.0 for j in range(n)):
        raise Singular()
    b_cols = b.to_columns()
    # y = Qᵀ B as n rows of k entries; then solve R X = y.
    y = [[dot(qj, bc) for bc in b_cols] for qj in q]
    r_rows = [[r[j][i] if j >= i else 0.0 for j in range(n)] for i in range(n)]
    back_upper(r_rows, y)
    return Matrix(y)
