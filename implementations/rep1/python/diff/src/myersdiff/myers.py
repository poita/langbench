"""Myers' O(ND) difference algorithm, linear-space "middle snake" variant.

Lines are first interned to small integers so that comparing two lines is
O(1).  The search then runs the forward and reverse greedy algorithms
simultaneously until they overlap (the *middle snake*), splits the problem at
that point and recurses on both halves.  Space is O(N + M) and the recursion
depth is O(log D).  The result is always a minimum-cost script.

Reference: E. W. Myers, "An O(ND) Difference Algorithm and Its Variations",
Algorithmica 1 (1986), section 4b.
"""

from __future__ import annotations

from collections.abc import Sequence

from .script import DELETE, INSERT, KEEP, Edit


def intern_lines(a: Sequence[str], b: Sequence[str]) -> tuple[list[int], list[int]]:
    """Map every distinct line of *a* and *b* to a small integer id."""
    ids: dict[str, int] = {}
    setdefault = ids.setdefault
    ia = [setdefault(s, len(ids)) for s in a]
    ib = [setdefault(s, len(ids)) for s in b]
    return ia, ib


def _bisect(a: list[int], b: list[int]) -> tuple[int, int]:
    """Find a point (x, y) on some shortest path through the edit graph.

    *a* and *b* are non-empty and differ in their first and last elements, so
    the optimal cost is at least 2 and both halves of the split are strictly
    smaller than the input.
    """
    n = len(a)
    m = len(b)
    max_d = (n + m + 1) // 2
    off = max_d + 1
    size = 2 * max_d + 4
    vf = [-1] * size
    vb = [-1] * size
    vf[off + 1] = 0
    vb[off + 1] = 0
    delta = n - m
    odd = delta & 1
    # Diagonal ranges clipped to the edit grid.
    f_lo = f_hi = b_lo = b_hi = 0
    for d in range(max_d + 1):
        # Forward pass.
        for k in range(-d + f_lo, d + 1 - f_hi, 2):
            i = off + k
            if k == -d or (k != d and vf[i - 1] < vf[i + 1]):
                x = vf[i + 1]
            else:
                x = vf[i - 1] + 1
            y = x - k
            while x < n and y < m and a[x] == b[y]:
                x += 1
                y += 1
            vf[i] = x
            if x > n:
                f_hi += 2
            elif y > m:
                f_lo += 2
            elif odd:
                j = off + delta - k
                if 0 <= j < size and vb[j] != -1 and x + vb[j] >= n:
                    return x, y
        # Reverse pass (coordinates measured from the ends).
        for k in range(-d + b_lo, d + 1 - b_hi, 2):
            i = off + k
            if k == -d or (k != d and vb[i - 1] < vb[i + 1]):
                x = vb[i + 1]
            else:
                x = vb[i - 1] + 1
            y = x - k
            while x < n and y < m and a[n - 1 - x] == b[m - 1 - y]:
                x += 1
                y += 1
            vb[i] = x
            if x > n:
                b_hi += 2
            elif y > m:
                b_lo += 2
            elif not odd:
                j = off + delta - k
                if 0 <= j < size and vf[j] != -1 and vf[j] + x >= n:
                    fx = vf[j]
                    return fx, fx - (delta - k)
    raise AssertionError("middle snake not found")  # pragma: no cover


def diff_ids(a: Sequence[int], b: Sequence[int]) -> list[tuple[str, int]]:
    """Shortest edit script over integer sequences.

    Returns ``(tag, index)`` pairs: the index refers to *a* for keep and
    delete, and to *b* for insert.
    """
    a = list(a)
    b = list(b)
    out: list[tuple[str, int]] = []

    def solve(a0: int, a1: int, b0: int, b1: int) -> None:
        # Trim the common prefix and suffix.
        while a0 < a1 and b0 < b1 and a[a0] == b[b0]:
            out.append((KEEP, a0))
            a0 += 1
            b0 += 1
        tail = 0
        while a0 < a1 and b0 < b1 and a[a1 - 1] == b[b1 - 1]:
            a1 -= 1
            b1 -= 1
            tail += 1
        if a0 == a1:
            out.extend((INSERT, j) for j in range(b0, b1))
        elif b0 == b1:
            out.extend((DELETE, i) for i in range(a0, a1))
        else:
            x, y = _bisect(a[a0:a1], b[b0:b1])
            solve(a0, a0 + x, b0, b0 + y)
            solve(a0 + x, a1, b0 + y, b1)
        out.extend((KEEP, a1 + t) for t in range(tail))

    solve(0, len(a), 0, len(b))
    return out


def diff(a: Sequence[str], b: Sequence[str]) -> list[Edit]:
    """Return a minimum-cost edit script turning *a* into *b*.

    Cost is the number of deletions plus insertions, which equals
    ``len(a) + len(b) - 2 * LCS(a, b)``.
    """
    ia, ib = intern_lines(a, b)
    return [
        Edit(tag, b[i] if tag == INSERT else a[i]) for tag, i in diff_ids(ia, ib)
    ]
