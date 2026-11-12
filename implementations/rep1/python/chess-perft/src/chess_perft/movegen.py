"""Legal move generation and bulk move counting.

Legality is decided from the king's *checkers* and the *pinned* pieces:

* a piece pinned to its king may only move along the pin line;
* in single check every non-king move must capture the checker or block the
  check; in double check only the king moves;
* king moves are filtered with the opponent's attack map (computed with the
  king lifted off the board, so sliders "see through" it);
* only en passant captures are verified by playing them out, because removing
  two pawns from one rank can expose the king to a rook or queen.

:func:`generate_legal_moves` returns packed moves; :func:`count_legal_moves`
returns just their number and is what perft uses at the last ply.
"""

from __future__ import annotations

from .constants import (
    BISHOP, CASTLE_BK, CASTLE_BQ, CASTLE_WK, CASTLE_WQ, FULL, KING, KNIGHT,
    NOT_FILE_A, NOT_FILE_H, PAWN, QUEEN, RANK_1, RANK_2, RANK_3, RANK_6, RANK_7, RANK_8, ROOK,
    WHITE,
)
from .moves import FLAG_CASTLE, FLAG_DOUBLE, FLAG_EN_PASSANT
from .tables import (
    BETWEEN, BISHOP_ATT, BISHOP_MASK, KING_ATT, KNIGHT_ATT, PAWN_ATT, ROOK_ATT, ROOK_MASK,
)

_PROMOTION_RANK = (RANK_8, RANK_1)
_PROMOTION_PIECES = (QUEEN, ROOK, BISHOP, KNIGHT)

# Squares that must be empty / unattacked for each castling move.
_F1G1 = 0x60
_B1C1D1 = 0x0E
_C1D1 = 0x0C
_F8G8 = _F1G1 << 56
_B8C8D8 = _B1C1D1 << 56
_C8D8 = _C1D1 << 56


def attacked_squares(pos, colour: int, occupied: int) -> int:
    """Bitboard of every square attacked by ``colour`` given blockers ``occupied``."""
    pawns, knights, bishops, rooks, queens, king = pos.pcs[colour]
    att = KING_ATT[king.bit_length() - 1]
    if colour == WHITE:
        att |= ((pawns & NOT_FILE_A) << 7 | (pawns & NOT_FILE_H) << 9) & FULL
    else:
        att |= (pawns & NOT_FILE_A) >> 9 | (pawns & NOT_FILE_H) >> 7
    while knights:
        low = knights & -knights
        att |= KNIGHT_ATT[low.bit_length() - 1]
        knights ^= low
    diag = bishops | queens
    while diag:
        low = diag & -diag
        sq = low.bit_length() - 1
        att |= BISHOP_ATT[sq][occupied & BISHOP_MASK[sq]]
        diag ^= low
    orth = rooks | queens
    while orth:
        low = orth & -orth
        sq = low.bit_length() - 1
        att |= ROOK_ATT[sq][occupied & ROOK_MASK[sq]]
        orth ^= low
    return att


def attackers_of(pos, sq: int, colour: int, occupied: int) -> int:
    """Bitboard of ``colour``'s pieces attacking ``sq`` given blockers ``occupied``."""
    pawns, knights, bishops, rooks, queens, king = pos.pcs[colour]
    return (
        (KNIGHT_ATT[sq] & knights)
        | (PAWN_ATT[colour ^ 1][sq] & pawns)
        | (KING_ATT[sq] & king)
        | (BISHOP_ATT[sq][occupied & BISHOP_MASK[sq]] & (bishops | queens))
        | (ROOK_ATT[sq][occupied & ROOK_MASK[sq]] & (rooks | queens))
    )


def is_attacked(pos, sq: int, by_colour: int) -> bool:
    """Whether ``by_colour`` attacks ``sq`` in the current position."""
    return attackers_of(pos, sq, by_colour, pos.occ[0] | pos.occ[1]) != 0


def _king_danger(pos, us):
    """Return ``(ksq, checkers, pinned, pin_rays)`` for the side ``us``.

    ``pinned`` is the bitboard of ``us``'s pieces pinned to the king and
    ``pin_rays[sq]`` the squares (pinner included) such a piece may move to.
    """
    them = us ^ 1
    own = pos.occ[us]
    opp = pos.occ[them]
    allocc = own | opp
    ksq = pos.pcs[us][KING].bit_length() - 1
    ep, en, eb, er, eq, _ = pos.pcs[them]
    rq = er | eq
    bq = eb | eq
    checkers = (KNIGHT_ATT[ksq] & en) | (PAWN_ATT[us][ksq] & ep)
    checkers |= ROOK_ATT[ksq][allocc & ROOK_MASK[ksq]] & rq
    checkers |= BISHOP_ATT[ksq][allocc & BISHOP_MASK[ksq]] & bq
    pinned = 0
    pin_rays = None
    # Enemy sliders that would hit the king if only enemy pieces blocked.
    cand = (ROOK_ATT[ksq][opp & ROOK_MASK[ksq]] & rq) | (BISHOP_ATT[ksq][opp & BISHOP_MASK[ksq]] & bq)
    if cand:
        pin_rays = {}
        while cand:
            low = cand & -cand
            cand ^= low
            line = BETWEEN[ksq][low.bit_length() - 1]
            blockers = line & own
            if blockers and not blockers & (blockers - 1):
                pinned |= blockers
                pin_rays[blockers.bit_length() - 1] = line | low
    return ksq, checkers, pinned, pin_rays


def _en_passant_origins(pos, us, ksq, allocc):
    """Bitboard of origin squares of legal en passant captures."""
    ep = pos.ep
    them = us ^ 1
    mine = pos.pcs[us]
    cands = PAWN_ATT[them][ep] & mine[PAWN]
    if not cands:
        return 0
    capb = 1 << (ep - 8 if us == WHITE else ep + 8)
    epb = 1 << ep
    ep_p, ep_n, ep_b, ep_r, ep_q, _ = pos.pcs[them]
    legal = 0
    while cands:
        low = cands & -cands
        cands ^= low
        occ2 = (allocc ^ low ^ capb) | epb
        if (
            ROOK_ATT[ksq][occ2 & ROOK_MASK[ksq]] & (ep_r | ep_q)
            or BISHOP_ATT[ksq][occ2 & BISHOP_MASK[ksq]] & (ep_b | ep_q)
            or KNIGHT_ATT[ksq] & ep_n
            or PAWN_ATT[us][ksq] & (ep_p ^ capb)
        ):
            continue
        legal |= low
    return legal


def _castle_targets(pos, us, allocc, att):
    """Destination squares of the legal castling moves (side not in check)."""
    out = []
    rights = pos.castling
    if us == WHITE:
        if rights & CASTLE_WK and not (allocc | att) & _F1G1:
            out.append(6)
        if rights & CASTLE_WQ and not allocc & _B1C1D1 and not att & _C1D1:
            out.append(2)
    else:
        if rights & CASTLE_BK and not (allocc | att) & _F8G8:
            out.append(62)
        if rights & CASTLE_BQ and not allocc & _B8C8D8 and not att & _C8D8:
            out.append(58)
    return out


def _pawn_targets(us, sq, ray, allocc, opp, pushmask, capmask):
    """``(single_pushes, double_pushes, captures)`` bitboards of one pawn."""
    bit = 1 << sq
    if us == WHITE:
        one = (bit << 8) & (FULL ^ allocc)
        two = ((one & RANK_3) << 8) & (FULL ^ allocc)
    else:
        one = (bit >> 8) & (FULL ^ allocc)
        two = ((one & RANK_6) >> 8) & (FULL ^ allocc)
    ok = pushmask & ray
    return one & ok, two & ok, PAWN_ATT[us][sq] & opp & capmask & ray


def generate_legal_moves(pos) -> list[int]:
    """Return every legal move of the side to move as packed ints."""
    us = pos.stm
    them = us ^ 1
    mine = pos.pcs[us]
    own = pos.occ[us]
    opp = pos.occ[them]
    allocc = own | opp
    ksq, checkers, pinned, pin_rays = _king_danger(pos, us)
    moves = []
    add = moves.append

    att = attacked_squares(pos, them, allocc ^ mine[KING])
    targets = KING_ATT[ksq] & ~own & ~att
    while targets:
        low = targets & -targets
        targets ^= low
        add(ksq | (low.bit_length() - 1) << 6)
    if checkers & (checkers - 1):  # double check
        return moves

    if checkers:
        csq = checkers.bit_length() - 1
        capmask = checkers
        pushmask = BETWEEN[ksq][csq]
        tmask = checkers | pushmask
    else:
        capmask = pushmask = FULL
        tmask = FULL ^ own
        if pos.castling:
            for to in _castle_targets(pos, us, allocc, att):
                add(ksq | to << 6 | FLAG_CASTLE << 15)

    # Knights, bishops, rooks and queens.
    for piece, pieces in (
        (KNIGHT, mine[KNIGHT]), (BISHOP, mine[BISHOP]), (ROOK, mine[ROOK]), (QUEEN, mine[QUEEN])
    ):
        while pieces:
            low = pieces & -pieces
            pieces ^= low
            sq = low.bit_length() - 1
            if piece == KNIGHT:
                tgt = KNIGHT_ATT[sq]
            elif piece == BISHOP:
                tgt = BISHOP_ATT[sq][allocc & BISHOP_MASK[sq]]
            elif piece == ROOK:
                tgt = ROOK_ATT[sq][allocc & ROOK_MASK[sq]]
            else:
                tgt = BISHOP_ATT[sq][allocc & BISHOP_MASK[sq]] | ROOK_ATT[sq][allocc & ROOK_MASK[sq]]
            tgt &= tmask
            if pinned & low:
                tgt &= pin_rays[sq]
            while tgt:
                tl = tgt & -tgt
                tgt ^= tl
                add(sq | (tl.bit_length() - 1) << 6)

    # Pawns.
    promo_rank = _PROMOTION_RANK[us]
    pawns = mine[PAWN]
    while pawns:
        low = pawns & -pawns
        pawns ^= low
        sq = low.bit_length() - 1
        ray = pin_rays[sq] if pinned & low else FULL
        one, two, caps = _pawn_targets(us, sq, ray, allocc, opp, pushmask, capmask)
        for bb in (one, caps):
            while bb:
                tl = bb & -bb
                bb ^= tl
                to = tl.bit_length() - 1
                if tl & promo_rank:
                    for promo in _PROMOTION_PIECES:
                        add(sq | to << 6 | promo << 12)
                else:
                    add(sq | to << 6)
        while two:
            tl = two & -two
            two ^= tl
            add(sq | (tl.bit_length() - 1) << 6 | FLAG_DOUBLE << 15)

    if pos.ep >= 0:
        origins = _en_passant_origins(pos, us, ksq, allocc)
        while origins:
            low = origins & -origins
            origins ^= low
            add(low.bit_length() - 1 | pos.ep << 6 | FLAG_EN_PASSANT << 15)
    return moves


def count_legal_moves(pos) -> int:
    """Return the number of legal moves of the side to move.

    Equivalent to ``len(generate_legal_moves(pos))`` but never builds the moves:
    target sets are counted with ``int.bit_count``.  This is the hot path of
    perft, so it is written for speed rather than brevity.
    """
    us = pos.stm
    them = us ^ 1
    mine = pos.pcs[us]
    own = pos.occ[us]
    opp = pos.occ[them]
    allocc = own | opp
    ksq, checkers, pinned, pin_rays = _king_danger(pos, us)

    att = attacked_squares(pos, them, allocc ^ mine[KING])
    targets = KING_ATT[ksq] & ~own & ~att
    n = targets.bit_count()
    if checkers & (checkers - 1):  # double check
        return n

    if checkers:
        csq = checkers.bit_length() - 1
        capmask = checkers
        pushmask = BETWEEN[ksq][csq]
        tmask = checkers | pushmask
    else:
        capmask = pushmask = FULL
        tmask = FULL ^ own
        if pos.castling:
            n += len(_castle_targets(pos, us, allocc, att))

    pawns, knights, bishops, rooks, queens, _ = mine
    if pinned:
        knights &= ~pinned  # a pinned knight can never move
    while knights:
        low = knights & -knights
        knights ^= low
        n += (KNIGHT_ATT[low.bit_length() - 1] & tmask).bit_count()
    diag = bishops | queens
    while diag:
        low = diag & -diag
        diag ^= low
        sq = low.bit_length() - 1
        tgt = BISHOP_ATT[sq][allocc & BISHOP_MASK[sq]] & tmask
        if pinned & low:
            tgt &= pin_rays[sq]
        n += tgt.bit_count()
    orth = rooks | queens
    while orth:
        low = orth & -orth
        orth ^= low
        sq = low.bit_length() - 1
        tgt = ROOK_ATT[sq][allocc & ROOK_MASK[sq]] & tmask
        if pinned & low:
            tgt &= pin_rays[sq]
        n += tgt.bit_count()

    # Pawns: all unpinned pawns at once with shifts, pinned ones one by one.
    free = pawns & ~pinned if pinned else pawns
    empty = FULL ^ allocc
    capt = opp & capmask
    if us == WHITE:
        one = (free << 8) & empty
        two = ((one & RANK_3) << 8) & empty & pushmask
        cap1 = ((free & NOT_FILE_A) << 7) & capt
        cap2 = ((free & NOT_FILE_H) << 9) & capt
        promo_from = RANK_7
    else:
        one = (free >> 8) & empty
        two = ((one & RANK_6) >> 8) & empty & pushmask
        cap1 = ((free & NOT_FILE_H) >> 7) & capt
        cap2 = ((free & NOT_FILE_A) >> 9) & capt
        promo_from = RANK_2
    one &= pushmask
    n += one.bit_count() + two.bit_count() + cap1.bit_count() + cap2.bit_count()
    if free & promo_from:  # each promotion is four moves, three more than counted
        promo_to = _PROMOTION_RANK[us]
        n += 3 * ((one & promo_to).bit_count() + (cap1 & promo_to).bit_count() + (cap2 & promo_to).bit_count())
    if pinned:
        pp = pawns & pinned
        promo_to = _PROMOTION_RANK[us]
        while pp:
            low = pp & -pp
            pp ^= low
            sq = low.bit_length() - 1
            one, two, caps = _pawn_targets(us, sq, pin_rays[sq], allocc, opp, pushmask, capmask)
            n += one.bit_count() + two.bit_count() + caps.bit_count()
            n += 3 * ((one | caps) & promo_to).bit_count()

    if pos.ep >= 0:
        n += _en_passant_origins(pos, us, ksq, allocc).bit_count()
    return n
