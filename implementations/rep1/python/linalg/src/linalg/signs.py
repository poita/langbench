"""Sign convention for eigenvectors and singular vectors."""

from __future__ import annotations

from collections.abc import Sequence


def needs_flip(column: Sequence[float]) -> bool:
    """Return True if ``column`` must be negated to be sign-normalised.

    The convention: the entry of largest magnitude (the smallest index among
    ties) is made non-negative.  An all-zero column is left alone.
    """
    best = -1.0
    index = 0
    for i, value in enumerate(column):
        magnitude = abs(value)
        if magnitude > best:
            best = magnitude
            index = i
    return column[index] < 0.0
