import random

import pytest

from chess_perft import Position, count_legal_moves, generate_legal_moves, move_to_uci

KIWIPETE = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"


def uci(fen):
    return sorted(move_to_uci(m) for m in Position.from_fen(fen).legal_moves())


def test_start_moves():
    moves = uci("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
    assert len(moves) == 20 and "e2e4" in moves and "g1f3" in moves


def test_promotions_four_each():
    assert uci("8/P1k5/K7/8/8/8/8/8 w - - 0 1") == [
        "a6a5", "a6b5", "a7a8b", "a7a8n", "a7a8q", "a7a8r"]


def test_castling_rules():
    assert {"e1g1", "e1c1"} <= set(uci("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"))
    # The rook on b8 attacks b1 (allowed); the one on g8 attacks g1 (not allowed).
    moves = uci("1r4r1/7k/8/8/8/8/8/R3K2R w KQ - 0 1")
    assert "e1c1" in moves and "e1g1" not in moves
    # f1 attacked: kingside is illegal, queenside is fine.
    moves = uci("5r1k/8/8/8/8/8/8/R3K2R w KQ - 0 1")
    assert "e1g1" not in moves and "e1c1" in moves
    # d1 attacked: queenside is illegal (c1 only crossed), kingside is fine.
    moves = uci("3r3k/8/8/8/8/8/8/R3K2R w KQ - 0 1")
    assert "e1c1" not in moves and "e1g1" in moves
    # in check: no castling at all
    moves = uci("4r2k/8/8/8/8/8/8/R3K2R w KQ - 0 1")
    assert "e1g1" not in moves and "e1c1" not in moves
    # blocked path
    assert "e1c1" not in uci("r3k2r/8/8/8/8/8/8/RN2K2R w KQkq - 0 1")


def test_en_passant_discovered_check_is_illegal():
    # Both pawns leave the 5th rank, exposing the white king to the rook.
    assert "e5d6" not in uci("8/8/8/K2pP2r/8/8/8/7k w - d6 0 1")
    assert "e5d6" in uci("8/8/8/3pP3/8/8/8/K6k w - d6 0 1")


def test_en_passant_resolves_pawn_check():
    # White's pawn on d4 (just pushed) checks the king on e5; black's c4 pawn
    # may remove it by capturing en passant.
    moves = uci("8/8/8/4k3/2pP4/8/8/4K3 b - d3 0 1")
    assert "c4d3" in moves


def test_pins_restrict_moves():
    # Pinned bishop on e2 may not leave the e-file (it cannot move at all).
    moves = uci("4r2k/8/8/8/8/8/4B3/4K3 w - - 0 1")
    assert not [m for m in moves if m.startswith("e2")]
    # Pinned rook slides along the pin line only.
    moves = uci("4r2k/8/8/8/8/8/4R3/4K3 w - - 0 1")
    assert sorted(m for m in moves if m.startswith("e2")) == [
        "e2e3", "e2e4", "e2e5", "e2e6", "e2e7", "e2e8"]


def test_double_check_only_king_moves():
    moves = uci("4k3/8/8/8/8/2n5/4r3/4K3 w - - 0 1")
    assert all(m.startswith("e1") for m in moves)


def test_king_cannot_retreat_along_checking_line():
    # The rook on a1 checks along rank 1: f1 is behind the king and still attacked.
    assert uci("4k3/8/8/8/8/8/8/r3K3 w - - 0 1") == ["e1d2", "e1e2", "e1f2"]


def test_no_legal_moves():
    assert uci("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1") == []  # stalemate
    assert uci("7k/6Q1/6K1/8/8/8/8/8 b - - 0 1") == []  # mate


POSITIONS = [
    KIWIPETE,
    "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
    "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
]


@pytest.mark.parametrize("fen", POSITIONS)
def test_count_matches_generation_along_random_games(fen):
    rng = random.Random(7)
    for _ in range(30):
        pos = Position.from_fen(fen)
        for _ply in range(60):
            moves = generate_legal_moves(pos)
            assert count_legal_moves(pos) == len(moves)
            assert len(set(moves)) == len(moves)
            if not moves:
                break
            pos.make(rng.choice(moves))


def test_generated_moves_are_legal_by_brute_force():
    """Cross-check the pin/check logic: no move may leave the king attacked."""
    rng = random.Random(3)
    for fen in POSITIONS:
        pos = Position.from_fen(fen)
        for _ in range(80):
            moves = pos.legal_moves()
            if not moves:
                break
            for move in moves:
                mover = pos.stm
                undo = pos.make(move)
                king = pos.king_square(mover)
                from chess_perft.movegen import is_attacked

                assert not is_attacked(pos, king, mover ^ 1), (pos.to_fen(), move_to_uci(move))
                pos.unmake(move, undo)
            pos.make(rng.choice(moves))
