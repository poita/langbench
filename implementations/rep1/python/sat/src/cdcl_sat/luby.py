"""The Luby restart sequence."""

from __future__ import annotations


def luby(y: float, i: int) -> float:
    """Return ``y ** k`` where ``k`` is the exponent of the ``i``-th (0-based)
    element of the Luby sequence 1 1 2 1 1 2 4 1 1 2 1 1 2 4 8 ...
    """
    size, seq = 1, 0
    while size < i + 1:
        seq += 1
        size = 2 * size + 1
    while size - 1 != i:
        size = (size - 1) >> 1
        seq -= 1
        i %= size
    return y**seq
