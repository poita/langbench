from chess_perft.constants import parse_square, square_name
from chess_perft.tables import (
    BETWEEN, KING_ATT, KNIGHT_ATT, PAWN_ATT, bishop_attacks, queen_attacks, rook_attacks,
)


def bb(*names):
    out = 0
    for n in names:
        out |= 1 << parse_square(n)
    return out


def test_square_names_round_trip():
    assert all(parse_square(square_name(s)) == s for s in range(64))
    assert parse_square("a1") == 0 and parse_square("h8") == 63


def test_leapers():
    assert KNIGHT_ATT[parse_square("a1")] == bb("b3", "c2")
    assert KNIGHT_ATT[parse_square("e4")].bit_count() == 8
    assert KING_ATT[parse_square("h8")] == bb("g8", "g7", "h7")
    assert PAWN_ATT[0][parse_square("e2")] == bb("d3", "f3")
    assert PAWN_ATT[1][parse_square("a7")] == bb("b6")


def test_between():
    assert BETWEEN[parse_square("a1")][parse_square("a4")] == bb("a2", "a3")
    assert BETWEEN[parse_square("a1")][parse_square("d4")] == bb("b2", "c3")
    assert BETWEEN[parse_square("d4")][parse_square("a1")] == bb("b2", "c3")
    assert BETWEEN[parse_square("a1")][parse_square("b3")] == 0
    assert BETWEEN[parse_square("a1")][parse_square("b2")] == 0


def test_sliders_empty_and_blocked():
    assert rook_attacks(parse_square("d4"), 0).bit_count() == 14
    assert bishop_attacks(parse_square("a1"), 0).bit_count() == 7
    occ = bb("d6", "f4")
    assert rook_attacks(parse_square("d4"), occ) & occ == occ
    assert not rook_attacks(parse_square("d4"), occ) & bb("d7", "g4")
    assert bishop_attacks(parse_square("c1"), bb("e3")) == bb("b2", "a3", "d2", "e3")
    assert queen_attacks(parse_square("a1"), 0).bit_count() == 21


def test_slider_tables_match_ray_walk():
    # Exhaustive-ish check against a naive implementation on pseudo-random occupancies.
    import random

    rng = random.Random(1)
    for _ in range(2000):
        sq = rng.randrange(64)
        occ = rng.getrandbits(64) & rng.getrandbits(64)
        for dirs, fn in (
            (((1, 0), (-1, 0), (0, 1), (0, -1)), rook_attacks),
            (((1, 1), (1, -1), (-1, 1), (-1, -1)), bishop_attacks),
        ):
            expect = 0
            for df, dr in dirs:
                f, r = (sq & 7) + df, (sq >> 3) + dr
                while 0 <= f < 8 and 0 <= r < 8:
                    expect |= 1 << (r * 8 + f)
                    if occ >> (r * 8 + f) & 1:
                        break
                    f += df
                    r += dr
            assert fn(sq, occ) == expect
