import pytest

from chess_perft import START_FEN, FenError, Position
from chess_perft.constants import (
    BLACK, CASTLE_BK, CASTLE_BQ, CASTLE_WK, CASTLE_WQ, NO_EP, WHITE, parse_square,
)
from chess_perft.moves import (
    FLAG_CASTLE, FLAG_DOUBLE, FLAG_EN_PASSANT, make_move, move_flag, move_origin,
    move_promotion, move_target, move_to_uci,
)

KIWIPETE = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"


def test_start_position():
    pos = Position.from_fen(START_FEN)
    assert pos.stm == WHITE
    assert pos.castling == CASTLE_WK | CASTLE_WQ | CASTLE_BK | CASTLE_BQ
    assert pos.ep == NO_EP
    assert pos.occ[WHITE].bit_count() == 16 and pos.occ[BLACK].bit_count() == 16
    assert pos.king_square(WHITE) == 4 and pos.king_square(BLACK) == 60
    assert pos.to_fen() == START_FEN


def test_fen_round_trip():
    for fen in (KIWIPETE, "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 b - - 0 1",
                "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2"):
        assert Position.from_fen(fen).to_fen().split()[:4] == fen.split()[:4]


def test_counters_optional_and_ignored():
    a = Position.from_fen("8/8/8/8/8/8/8/K6k w - - 17 40")
    b = Position.from_fen("8/8/8/8/8/8/8/K6k w - -")
    assert a == b


def test_inconsistent_castling_and_ep_dropped():
    pos = Position.from_fen("4k3/8/8/8/8/8/8/4K3 w KQkq - 0 1")
    assert pos.castling == 0
    pos = Position.from_fen("4k3/8/8/8/8/8/8/4K3 w - e6 0 1")
    assert pos.ep == NO_EP


@pytest.mark.parametrize("fen", [
    "", "8/8/8/8/8/8/8/8 w - - 0 1", "4k3/8/8/8/8/8/8/4K3 x - - 0 1",
    "4k3/8/8/8/8/8/8/4K3 w KK - 0 1", "4k3/8/8/8/8/8/8/4K3 w - e9 0 1",
    "4k3/8/8/8/8/8/8/4K2 w - - 0 1", "4k3/8/8/8/8/8/8 w - - 0 1",
    "4k3/8/8/8/8/8/8/4K3 w - - a 1",
])
def test_bad_fen(fen):
    with pytest.raises(FenError):
        Position.from_fen(fen)


def test_move_fields_and_uci():
    m = make_move(parse_square("a7"), parse_square("a8"), 4)
    assert (move_origin(m), move_target(m), move_promotion(m), move_flag(m)) == (48, 56, 4, 0)
    assert move_to_uci(m) == "a7a8q"
    assert move_to_uci(make_move(4, 6, 0, FLAG_CASTLE)) == "e1g1"


def test_make_unmake_restores_everything():
    for fen in (KIWIPETE, "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
                "rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 3"):
        pos = Position.from_fen(fen)
        before = pos.copy()
        for move in pos.legal_moves():
            undo = pos.make(move)
            pos.unmake(move, undo)
            assert pos == before
            assert pos.board == before.board and pos.occ == before.occ


def test_castling_moves_the_rook_and_clears_rights():
    pos = Position.from_fen(KIWIPETE)
    pos.make(pos.parse_uci("e1g1"))
    assert pos.to_fen().startswith("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R4RK1 b kq")


def test_double_push_sets_ep_and_en_passant_removes_pawn():
    pos = Position.from_fen("4k3/8/8/3p4/8/8/4P3/4K3 w - - 0 1")
    pos.make(pos.parse_uci("e2e4"))
    assert pos.ep == parse_square("e3")
    pos.make(pos.parse_uci("d5d4"))
    assert pos.ep == NO_EP
    pos.make(pos.parse_uci("e4e5"))
    pos = Position.from_fen("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1")
    move = pos.parse_uci("e5d6")
    assert move_flag(move) == FLAG_EN_PASSANT
    pos.make(move)
    assert pos.to_fen().startswith("4k3/8/3P4/8/8/8/8/4K3 b")


def test_rook_capture_removes_castling_right():
    pos = Position.from_fen("r3k2r/8/8/8/8/8/6B1/R3K2R w KQkq - 0 1")
    pos.make(pos.parse_uci("g2a8"))
    assert pos.castling == CASTLE_WK | CASTLE_WQ | CASTLE_BK


def test_parse_uci_rejects_illegal():
    pos = Position.from_fen(START_FEN)
    with pytest.raises(ValueError):
        pos.parse_uci("e2e5")
    with pytest.raises(ValueError):
        pos.parse_uci("zz")
    assert move_flag(pos.parse_uci("e2e4")) == FLAG_DOUBLE


def test_in_check():
    assert not Position.from_fen(START_FEN).in_check()
    assert Position.from_fen("4k3/8/8/8/8/8/4r3/4K3 w - - 0 1").in_check()
