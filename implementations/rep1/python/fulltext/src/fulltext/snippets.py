"""Best-window snippet selection."""

from __future__ import annotations

import re
from collections.abc import Sequence

from .analysis import WHITESPACE

__all__ = ["WINDOW", "best_window", "collapse_whitespace"]

#: Window width in tokens.
WINDOW = 30

_WS_RUN = re.compile("[" + WHITESPACE + "]+")


def collapse_whitespace(text: str) -> str:
    """Replace each run of the seven whitespace code points with one space."""
    return _WS_RUN.sub(" ", text)


def best_window(
    length: int,
    occurrences: Sequence[tuple[int, Sequence[int]]],
    width: int = WINDOW,
) -> int:
    """Return the start of the best window of a ``length``-token document.

    ``occurrences`` has one ``(n_terms, sorted start positions)`` entry per
    distinct positive atom. The best window has the most distinct atoms inside
    it, then the most occurrences, then the smallest start. Runs in
    O(length + occurrences) using difference arrays over window starts.
    """
    if length <= width:
        return 0
    last = length - width  # greatest window start
    total = [0] * (last + 2)
    distinct = [0] * (last + 2)
    for n_terms, positions in occurrences:
        if n_terms > width:
            continue  # can never fit in a window
        run_lo = run_hi = -1
        for p in positions:
            # window starts s with s <= p and p + n_terms - 1 <= s + width - 1
            lo = max(0, p + n_terms - width)
            hi = min(p, last)
            total[lo] += 1
            total[hi + 1] -= 1
            if run_hi < 0:
                run_lo, run_hi = lo, hi
            elif lo <= run_hi + 1:
                run_hi = max(run_hi, hi)
            else:
                distinct[run_lo] += 1
                distinct[run_hi + 1] -= 1
                run_lo, run_hi = lo, hi
        if run_hi >= 0:
            distinct[run_lo] += 1
            distinct[run_hi + 1] -= 1
    best = 0
    best_key = (-1, -1)
    n_atoms = n_occ = 0
    for s in range(last + 1):
        n_atoms += distinct[s]
        n_occ += total[s]
        key = (n_atoms, n_occ)
        if key > best_key:
            best_key = key
            best = s
    return best
