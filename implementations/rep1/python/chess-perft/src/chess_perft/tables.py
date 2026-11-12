"""Precomputed attack tables, built once at import time.

* ``KNIGHT_ATT[sq]`` / ``KING_ATT[sq]``: squares a knight / king on ``sq`` attacks.
* ``PAWN_ATT[colour][sq]``: squares a pawn of ``colour`` on ``sq`` attacks.
  Reversed, ``PAWN_ATT[enemy][sq]`` is where an attacking pawn of ``colour``
  would stand to attack ``sq``.
* ``BETWEEN[a][b]``: squares strictly between ``a`` and ``b`` when they share a
  rank, file or diagonal, otherwise ``0``.
* ``ROOK_ATT[sq][occ & ROOK_MASK[sq]]`` and the bishop equivalents give slider
  attacks for a blocker set.  The tables are dictionaries indexed by the
  relevant occupancy bits (no magic numbers are needed), see
  :func:`rook_attacks` and :func:`bishop_attacks`.
"""

from __future__ import annotations

from itertools import product

ROOK_DIRS = ((1, 0), (-1, 0), (0, 1), (0, -1))
BISHOP_DIRS = ((1, 1), (1, -1), (-1, 1), (-1, -1))
KNIGHT_JUMPS = ((1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2))
KING_STEPS = ROOK_DIRS + BISHOP_DIRS


def _leaper(steps, sq):
    f, r = sq & 7, sq >> 3
    bb = 0
    for df, dr in steps:
        nf, nr = f + df, r + dr
        if 0 <= nf < 8 and 0 <= nr < 8:
            bb |= 1 << (nr * 8 + nf)
    return bb


def _ray(sq, df, dr):
    """Squares from ``sq`` (exclusive) to the board edge in a direction."""
    f, r = (sq & 7) + df, (sq >> 3) + dr
    out = []
    while 0 <= f < 8 and 0 <= r < 8:
        out.append(r * 8 + f)
        f += df
        r += dr
    return out


KNIGHT_ATT = [_leaper(KNIGHT_JUMPS, s) for s in range(64)]
KING_ATT = [_leaper(KING_STEPS, s) for s in range(64)]
PAWN_ATT = [
    [_leaper(((-1, 1), (1, 1)), s) for s in range(64)],  # white
    [_leaper(((-1, -1), (1, -1)), s) for s in range(64)],  # black
]


def _build_between():
    table = [[0] * 64 for _ in range(64)]
    for a in range(64):
        for df, dr in KING_STEPS:
            acc = 0
            for b in _ray(a, df, dr):
                table[a][b] = acc
                acc |= 1 << b
    return table


BETWEEN = _build_between()


def _build_slider(dirs):
    """Return ``(masks, tables)`` for a slider moving along ``dirs``.

    ``masks[sq]`` holds the squares whose occupancy can change the attack set
    (every ray square except the final one on the board edge); ``tables[sq]``
    maps each subset of the mask to the resulting attack set.
    """
    masks, tables = [], []
    for sq in range(64):
        mask = 0
        table = {0: 0}
        for df, dr in dirs:
            ray = _ray(sq, df, dr)
            if not ray:
                continue
            relevant = ray[:-1]
            per_dir = []
            for subset in product((0, 1), repeat=len(relevant)):
                occ = 0
                for s, used in zip(relevant, subset):
                    if used:
                        occ |= 1 << s
                att = 0
                for s in ray:
                    att |= 1 << s
                    if occ >> s & 1:
                        break
                per_dir.append((occ, att))
            for s in relevant:
                mask |= 1 << s
            table = {o1 | o2: a1 | a2 for o1, a1 in table.items() for o2, a2 in per_dir}
        masks.append(mask)
        tables.append(table)
    return masks, tables


ROOK_MASK, ROOK_ATT = _build_slider(ROOK_DIRS)
BISHOP_MASK, BISHOP_ATT = _build_slider(BISHOP_DIRS)


def rook_attacks(sq: int, occupied: int) -> int:
    """Squares a rook on ``sq`` attacks given the ``occupied`` bitboard."""
    return ROOK_ATT[sq][occupied & ROOK_MASK[sq]]


def bishop_attacks(sq: int, occupied: int) -> int:
    """Squares a bishop on ``sq`` attacks given the ``occupied`` bitboard."""
    return BISHOP_ATT[sq][occupied & BISHOP_MASK[sq]]


def queen_attacks(sq: int, occupied: int) -> int:
    """Squares a queen on ``sq`` attacks given the ``occupied`` bitboard."""
    return rook_attacks(sq, occupied) | bishop_attacks(sq, occupied)
