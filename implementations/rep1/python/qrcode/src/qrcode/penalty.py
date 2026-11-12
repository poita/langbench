"""Mask penalty scoring (rules N1-N4)."""

from __future__ import annotations

import re
from typing import Sequence

_RUN = re.compile(r"0{5,}|1{5,}")
_FINDER_A = re.compile(r"(?=10111010000)")  # dark-first pattern
_FINDER_B = re.compile(r"(?=00001011101)")  # light-first pattern


def _line_penalty(line: str) -> int:
    """N1 and N3 contribution of a single row or column."""
    total = 0
    for m in _RUN.finditer(line):
        total += m.end() - m.start() - 2  # 3 + (len - 5)
    total += 40 * len(_FINDER_A.findall(line))
    total += 40 * len(_FINDER_B.findall(line))
    return total


def penalty(rows: Sequence[int], size: int) -> int:
    """Total penalty score of a complete symbol given as integer rows."""
    n = size
    fmt = f"0{n}b"
    strings = [format(r, fmt) for r in rows]
    total = 0

    # N1 + N3 on rows and columns.
    for s in strings:
        total += _line_penalty(s)
    for col in zip(*strings):
        total += _line_penalty("".join(col))

    # N2: 2x2 blocks of one colour.
    low = (1 << (n - 1)) - 1
    # same[y]: bit i set when modules at bit i and i+1 of row y are equal.
    same = [~(r ^ (r >> 1)) & low for r in rows]
    blocks = 0
    for y in range(n - 1):
        blocks += (same[y] & same[y + 1] & ~(rows[y] ^ rows[y + 1])).bit_count()
    total += 3 * blocks

    # N4: dark proportion.
    dark = sum(r.bit_count() for r in rows)
    k = abs(20 * dark - 10 * n * n) // (n * n)
    total += 10 * k
    return total
