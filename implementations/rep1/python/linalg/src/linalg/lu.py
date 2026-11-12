"""LU factorisation with partial pivoting, and its users."""

from __future__ import annotations

from dataclasses import dataclass

from ._triangular import back_upper, forward_unit_lower
from .errors import DimensionMismatch, NotSquare, Singular
from .matrix import Matrix


@dataclass(frozen=True)
class LU:
    """The factorisation ``P A = L U``.

    ``perm[i]`` is the index in the original matrix of the row now in row
    ``i``; ``swaps`` counts the row interchanges; ``packed`` holds the
    multipliers below the diagonal and ``U`` on and above it.
    """

    perm: tuple[int, ...]
    swaps: int
    packed: tuple[tuple[float, ...], ...]

    @property
    def n(self) -> int:
        return len(self.perm)

    @property
    def P(self) -> Matrix:
        n = self.n
        return Matrix([1.0 if j == self.perm[i] else 0.0 for j in range(n)] for i in range(n))

    @property
    def L(self) -> Matrix:
        return Matrix(
            [self.packed[i][j] if j < i else (1.0 if j == i else 0.0) for j in range(self.n)]
            for i in range(self.n)
        )

    @property
    def U(self) -> Matrix:
        return Matrix(
            [self.packed[i][j] if j >= i else 0.0 for j in range(self.n)]
            for i in range(self.n)
        )


def _eliminate(a: Matrix) -> tuple[list[list[float]], list[int], int, bool]:
    """Right-looking Gaussian elimination.

    Returns ``(M, perm, swaps, ok)``; ``ok`` is False if a pivot was exactly
    zero, in which case ``M`` is only partially reduced.
    """
    m = a.to_rows()
    n = len(m)
    perm = list(range(n))
    swaps = 0
    for k in range(n):
        p = max(range(k, n), key=lambda i: abs(m[i][k]))  # first maximum wins
        if abs(m[p][k]) == 0.0:
            return m, perm, swaps, False
        if p != k:
            m[k], m[p] = m[p], m[k]
            perm[k], perm[p] = perm[p], perm[k]
            swaps += 1
        row_k = m[k]
        pivot = row_k[k]
        tail = row_k[k + 1 :]
        for i in range(k + 1, n):
            row = m[i]
            f = row[k] / pivot
            row[k] = f
            row[k + 1 :] = [x - f * y for x, y in zip(row[k + 1 :], tail)]
    return m, perm, swaps, True


def lu_factor(a: Matrix) -> LU:
    """Factor a square matrix as ``P A = L U``.

    Raises :class:`NotSquare` or :class:`Singular` (a pivot of exactly 0.0).
    """
    if not a.is_square:
        raise NotSquare(f"shape {a.shape}")
    m, perm, swaps, ok = _eliminate(a)
    if not ok:
        raise Singular()
    return LU(tuple(perm), swaps, tuple(tuple(r) for r in m))


def det(a: Matrix) -> float:
    """Determinant; 0.0 for a matrix whose elimination meets a zero pivot."""
    if not a.is_square:
        raise NotSquare(f"shape {a.shape}")
    m, _, swaps, ok = _eliminate(a)
    if not ok:
        return 0.0
    product = 1.0
    for i in range(len(m)):
        product *= m[i][i]
    return -product if swaps % 2 else product


def lu_solve(f: LU, b: Matrix) -> Matrix:
    """Solve ``A X = B`` given the factorisation of ``A``."""
    if b.rows != f.n:
        raise DimensionMismatch(f"right-hand side has {b.rows} rows, expected {f.n}")
    rows = b.to_rows()
    y = [rows[f.perm[i]] for i in range(f.n)]
    forward_unit_lower(f.packed, y)
    back_upper(f.packed, y)
    return Matrix(y)


def solve(a: Matrix, b: Matrix) -> Matrix:
    """Solve ``A X = B`` for square ``A``.

    ``A`` must be square (checked before ``B``'s row count) and non-singular.
    """
    if not a.is_square:
        raise NotSquare(f"shape {a.shape}")
    if b.rows != a.rows:
        raise DimensionMismatch(f"right-hand side has {b.rows} rows, expected {a.rows}")
    return lu_solve(lu_factor(a), b)


def inv(a: Matrix) -> Matrix:
    """Inverse of a square, non-singular matrix (``solve(A, I)``)."""
    if not a.is_square:
        raise NotSquare(f"shape {a.shape}")
    return lu_solve(lu_factor(a), Matrix.identity(a.rows))
