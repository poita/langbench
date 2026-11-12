"""Elementwise sum and matrix product."""

from __future__ import annotations

from operator import add as _add

from ._arith import dot
from .errors import DimensionMismatch
from .matrix import Matrix


def add(a: Matrix, b: Matrix) -> Matrix:
    """Return ``A + B``.  Raises :class:`DimensionMismatch` on differing shapes."""
    if a.shape != b.shape:
        raise DimensionMismatch(f"cannot add {a.shape} and {b.shape}")
    return Matrix(map(_add, ra, rb) for ra, rb in zip(a.iter_rows(), b.iter_rows()))


def mul(a: Matrix, b: Matrix) -> Matrix:
    """Return the product ``A B`` by the classical triple loop.

    Each entry is one running sum over increasing ``k``.  Raises
    :class:`DimensionMismatch` unless ``A.cols == B.rows``.
    """
    if a.cols != b.rows:
        raise DimensionMismatch(f"cannot multiply {a.shape} by {b.shape}")
    b_cols = b.to_columns()
    return Matrix([dot(row, col) for col in b_cols] for row in a.iter_rows())


def transpose(a: Matrix) -> Matrix:
    """Return ``Aᵀ``."""
    return a.transpose()
