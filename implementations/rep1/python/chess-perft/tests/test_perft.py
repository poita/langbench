import pytest

from chess_perft import START_FEN, Position, divide, perft

KIWIPETE = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
POS3 = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1"
POS4 = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1"
POS5 = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8"
POS6 = "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10"

CASES = [
    (START_FEN, [1, 20, 400, 8902, 197281]),
    (KIWIPETE, [1, 48, 2039, 97862]),
    (POS3, [1, 14, 191, 2812, 43238]),
    (POS4, [1, 6, 264, 9467]),
    (POS5, [1, 44, 1486, 62379]),
    (POS6, [1, 46, 2079, 89890]),
]


@pytest.mark.parametrize("fen,expected", CASES)
def test_reference_values(fen, expected):
    pos = Position.from_fen(fen)
    for depth, count in enumerate(expected):
        assert perft(pos, depth) == count


def test_position_is_restored():
    pos = Position.from_fen(KIWIPETE)
    before = pos.copy()
    perft(pos, 3)
    assert pos == before and pos.board == before.board


def test_divide_sorted_and_sums_to_perft():
    pos = Position.from_fen(KIWIPETE)
    result = divide(pos, 3)
    assert [m for m, _ in result] == sorted(m for m, _ in result)
    assert len(result) == 48
    assert sum(c for _, c in result) == perft(pos, 3) == 97862


def test_divide_depth_one_all_ones():
    assert all(c == 1 for _, c in divide(Position.from_fen(START_FEN), 1))


def test_stalemate_and_mate_have_no_nodes():
    pos = Position.from_fen("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")
    assert perft(pos, 1) == perft(pos, 3) == 0
    assert divide(pos, 3) == []


def test_en_passant_pin_position():
    # Classic position where one en passant capture is illegal (rank pin).
    pos = Position.from_fen("8/8/8/8/k2Pp2Q/8/8/3K4 b - d3 0 1")
    assert "e4d3" not in pos.uci_moves()


def test_depth_validation():
    pos = Position.from_fen(START_FEN)
    with pytest.raises(ValueError):
        perft(pos, -1)
    with pytest.raises(ValueError):
        divide(pos, 0)


def test_deep_three_piece_position():
    assert perft(Position.from_fen("3k4/3p4/8/K1P4r/8/8/8/8 b - - 0 1"), 6) == 1134888
