"""Triangular substitution on row-major lists, shared by LU and QR solvers.

Right-hand sides are held as a list of rows (``n`` rows of ``k`` entries) so
that every elimination step is one vectorised update across all ``k``
right-hand sides.  Each column is nevertheless processed exactly as if alone:
``x[i] = (b[i] - t[0] - t[1] - ...) / d`` with the terms subtracted one at a
time in increasing column order.
"""

from __future__ import annotations

from collections.abc import Sequence


def forward_unit_lower(lu: Sequence[Sequence[float]], y: list[list[float]]) -> None:
    """Solve ``L y = b`` in place, ``L`` unit lower triangular (below diagonal of ``lu``)."""
    for i in range(1, len(y)):
        acc = y[i]
        row = lu[i]
        for j in range(i):
            f = row[j]
            acc = [a - f * b for a, b in zip(acc, y[j])]
        y[i] = acc


def back_upper(u: Sequence[Sequence[float]], y: list[list[float]]) -> None:
    """Solve ``U x = y`` in place, ``U`` upper triangular (on/above diagonal of ``u``)."""
    n = len(y)
    for i in range(n - 1, -1, -1):
        acc = y[i]
        row = u[i]
        for j in range(i + 1, n):
            f = row[j]
            acc = [a - f * b for a, b in zip(acc, y[j])]
        d = row[i]
        y[i] = [a / d for a in acc]
