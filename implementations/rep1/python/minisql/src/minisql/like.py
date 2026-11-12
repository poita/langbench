"""LIKE pattern matching."""

from __future__ import annotations

import string

_ASCII_LOWER = str.maketrans(string.ascii_uppercase, string.ascii_lowercase)


def like_match(text: str, pattern: str) -> bool:
    """Match ``text`` against a LIKE ``pattern``.

    ``%`` matches any run of characters (including none) and ``_`` exactly one
    character; everything else matches itself, ignoring case for the 26 ASCII
    letters only. The whole text must match.

    This is the classic iterative wildcard matcher with a single backtrack
    point (the most recent ``%``), so it runs in O(len(text) * len(pattern))
    worst case and never builds a regular expression.
    """
    s = text.translate(_ASCII_LOWER)
    p = pattern.translate(_ASCII_LOWER)
    n, m = len(s), len(p)
    si = pi = 0
    star = -1  # index in p of the last '%'
    mark = 0  # index in s where that '%' currently stops matching
    while si < n:
        if pi < m and p[pi] == "%":
            star = pi
            mark = si
            pi += 1
        elif pi < m and (p[pi] == "_" or p[pi] == s[si]):
            si += 1
            pi += 1
        elif star >= 0:
            mark += 1
            si = mark
            pi = star + 1
        else:
            return False
    while pi < m and p[pi] == "%":
        pi += 1
    return pi == m
