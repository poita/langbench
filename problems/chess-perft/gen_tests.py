#!/usr/bin/env python3
"""Generate tests/*.in and tests/*.out for chess-perft.

Hand-written edge cases are embedded as literals; random positions are produced
by playing seeded random games with the reference move generator. Expected
outputs come from running reference/main.py on each input.
"""
import importlib.util
import os
import random
import subprocess
import sys

# Keep the reference directory free of bytecode caches.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")
REF = os.path.join(HERE, "reference", "main.py")

spec = importlib.util.spec_from_file_location("ref", REF)
ref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)

START = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
KIWIPETE = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
POS3 = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1"
POS4 = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1"
POS4M = "r2q1rk1/pP1p2pp/Q4n2/bbp1p3/Np6/1B3NBn/pPPP1PPP/R3K2R b KQ - 0 1"
POS5 = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8"
POS6 = "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10"

# Positions from the widely used perft edge-case suite (TalkChess / Martin
# Sedlak), each exercising one tricky rule.
EDGE_SUITE = [
    ("3k4/3p4/8/K1P4r/8/8/8/8 b - - 0 1", 6),          # illegal ep (pinned along rank)
    ("8/8/4k3/8/2p5/8/B2P2K1/8 w - - 0 1", 6),          # ep capture checks opponent
    ("8/8/1k6/2b5/2pP4/8/5K2/8 b - d3 0 1", 6),         # ep capture into a pin
    ("5k2/8/8/8/8/8/8/4K2R w K - 0 1", 6),              # short castling gives check
    ("3k4/8/8/8/8/8/8/R3K3 w Q - 0 1", 6),              # long castling gives check
    ("r3k2r/1b4bq/8/8/8/8/7B/R3K2R w KQkq - 0 1", 4),   # castling rights
    ("r3k2r/8/3Q4/8/8/5q2/8/R3K2R b KQkq - 0 1", 4),    # castling prevented
    ("2K2r2/4P3/8/8/8/8/8/3k4 w - - 0 1", 6),           # promote out of check
    ("8/8/1P2K3/8/2n5/1q6/8/5k2 b - - 0 1", 5),         # discovered check
    ("4k3/1P6/8/8/8/8/K7/8 w - - 0 1", 6),              # promote to give check
    ("8/P1k5/K7/8/8/8/8/8 w - - 0 1", 6),               # underpromote to give check
    ("K1k5/8/P7/8/8/8/8/8 w - - 0 1", 6),               # self stalemate
    ("8/k1P5/8/1K6/8/8/8/8 w - - 0 1", 7),              # stalemate and checkmate
    ("8/8/2k5/5q2/5n2/8/5K2/8 b - - 0 1", 4),           # stalemate and checkmate
]

HAND = [
    ("startpos_d1", [f"{START} 1"]),
    ("depth_zero", [f"{START} 0", f"{KIWIPETE} 0", "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1 0"]),
    ("startpos_divide1", [f"{START} divide 1"]),
    ("startpos_d2_d3", [f"{START} 2", f"{START} 3"]),
    ("no_legal_moves", [
        # Fool's mate: white is checkmated.
        "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3 1",
        "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3 divide 1",
        "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3 3",
        # Stalemate.
        "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1 1",
        "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1 divide 3",
        # Back-rank mate.
        "6k1/5ppp/8/8/8/8/8/4R1K1 b - - 0 1 divide 1",
        # Smothered mate.
        "6rk/6pp/8/6N1/8/8/8/6K1 b - - 0 1 divide 2",
    ]),
    ("promotions", [
        "8/P1k5/K7/8/8/8/8/8 w - - 0 1 divide 1",
        "1n1k4/P7/8/8/8/8/8/4K3 w - - 0 1 divide 1",      # push or capture promotion
        "4k3/8/8/8/8/8/p7/1N2K3 b - - 0 1 divide 1",      # black promotion incl. capture
        "r3k3/1P6/8/8/8/8/8/4K3 w q - 0 1 divide 2",      # capture on a8 removes black queenside right
        "4k3/8/8/8/8/8/p7/RN2K3 b Q - 0 1 divide 2",      # capture on a1 removes white queenside right
        "4k3/1P6/8/8/8/8/K7/8 w - - 0 1 divide 3",
        "2K2r2/4P3/8/8/8/8/8/3k4 w - - 0 1 divide 1",     # promotion must resolve check
        "8/2P5/8/8/8/8/k7/2r1K3 w - - 0 1 divide 1",      # pinned-file promotion is illegal
    ]),
    ("en_passant", [
        # Ep square present but no pawn can use it.
        "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1 divide 1",
        # Ordinary ep capture, either of two pawns may take.
        "4k3/8/8/2PpP3/8/8/8/4K3 w - d6 0 1 divide 1",
        # Horizontal pin: capturing en passant would expose the king along rank 4.
        "8/8/8/8/k2Pp2Q/8/8/3K4 b - d3 0 1 divide 1",
        # Diagonal pin on the capturing pawn.
        "8/8/1k6/2b5/2pP4/8/5K2/8 b - d3 0 1 divide 1",
        # Ep capture that resolves a check from the double-stepped pawn.
        "8/8/8/2k5/3Pp3/8/8/4K3 b - d3 0 1 divide 1",
        # The double push discovered a bishop check; ep capture does not resolve it.
        "3bk3/8/8/3Pp3/7K/8/8/8 w - e6 0 1 divide 1",
        # The would-be capturing pawn is pinned to its own king by the bishop on a2.
        "8/8/4k3/8/2pP4/8/B5K1/8 b - d3 0 1 divide 2",
        # Ep right lasts only one move.
        "4k3/8/8/2PpP3/8/8/8/4K3 w - d6 0 1 divide 2",
        # Black ep capture with two candidate pawns.
        "4k3/8/8/8/2pPp3/8/8/4K3 b - d3 0 1 divide 1",
    ]),
    ("castling", [
        "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1 divide 1",
        "r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1 divide 1",
        "4k3/8/8/8/8/8/8/R3K2R w KQ - 0 1 divide 1",
        "4k3/8/8/8/8/8/8/R3K2R w - - 0 1 divide 1",       # no rights
        "4k3/8/8/8/8/8/8/R3K2R w K - 0 1 divide 1",       # kingside only
        "4k3/8/8/8/8/8/5r2/R3K2R w KQ - 0 1 divide 1",    # f1 attacked
        "4k3/8/8/8/8/8/6r1/R3K2R w KQ - 0 1 divide 1",    # g1 attacked
        "4k3/8/8/8/8/8/3r4/R3K2R w KQ - 0 1 divide 1",    # d1 attacked
        "4k3/8/8/8/8/8/2r5/R3K2R w KQ - 0 1 divide 1",    # c1 attacked
        "4k3/8/8/8/8/8/1r6/R3K2R w KQ - 0 1 divide 1",    # b1 attacked: queenside still legal
        "4k3/8/8/8/8/8/4r3/R3K2R w KQ - 0 1 divide 1",    # in check: no castling
        "rn2k2r/8/8/8/8/8/8/RN2K2R w KQkq - 0 1 divide 1", # b1/b8 occupied
        "r3k1nr/8/8/8/8/8/8/R3KN1R w KQkq - 0 1 divide 1", # f-file occupied
        "4k3/8/8/8/8/8/8/R3K2R b - - 0 1 divide 1",       # lone black king
        "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1 divide 2",  # rights lost after king/rook moves
        "r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1 divide 2",
        "4k3/8/8/8/8/7b/8/R3K2R w KQ - 0 1 divide 1",     # bishop h3 attacks f1
        "4k3/8/8/8/8/8/8/R3K2r w Q - 0 1 divide 1",       # rook on h1 captured: only queenside
        # A right lost when the rook is captured on its corner is not regained
        # when another rook recaptures there (Nxh8 Rxh8 then no e8g8, etc.).
        "4k2r/8/6N1/8/8/8/K7/7r w k - 0 1 divide 4",
        "r3k3/8/1N6/8/8/8/1K6/r7 w q - 0 1 divide 4",
        "R7/1k6/8/8/8/1n6/8/R3K3 b Q - 0 1 divide 4",
        "7R/k7/8/8/8/6n1/8/4K2R b K - 0 1 divide 4",
    ]),
    ("checks_and_pins", [
        "4k3/4r3/8/8/8/8/4B3/4K3 w - - 0 1 divide 1",     # pinned bishop cannot move
        "q3k3/8/3N4/8/8/8/8/4RK2 b - - 0 1 divide 1",     # double check: king moves only
        "4k3/8/8/8/8/8/8/q2N1K2 w - - 0 1 divide 1",      # pinned knight
        "4k3/8/8/8/8/8/8/q2R1K2 w - - 0 1 divide 1",      # pinned rook moves along the pin
        "4k3/8/8/8/1b6/2P5/8/4K3 w - - 0 1 divide 1",     # pinned pawn may capture the pinner
        "4k3/8/8/8/8/8/8/r3K3 w - - 0 1 divide 1",        # king cannot step along the check ray
        "4k3/8/8/8/8/2b5/3q4/4K3 w - - 0 1 divide 1",     # cannot capture a protected checker
        "4k3/8/8/8/8/8/8/4K2r w - - 0 1 divide 1",        # rook check: capture, block, or move
        "4k3/8/8/8/8/8/3P4/4K2b w - - 0 1 divide 1",      # bishop check, pawn can capture... or block
        "3rk3/8/8/8/8/8/8/3QK3 w - - 0 1 divide 1",       # pinned queen along file
        "4k3/8/8/8/8/8/5n2/4K3 w - - 0 1 divide 1",       # knight check: only king moves
        "4k3/8/8/8/8/8/5n2/4K3 w - - 0 1 divide 3",
        "rnb1kbnr/pppp1ppp/8/4p3/5PPq/8/PPPPP2P/RNBQKBNR w KQkq - 1 3 divide 1",  # check, block with pawn
        "r1bqkbnr/pppp1ppp/2n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3 divide 2",
    ]),
]


def fen_of(pos):
    """Serialize a reference Position as a six-field FEN (clocks fixed at 0 1)."""
    rows = []
    for rank in range(7, -1, -1):
        row = ""
        empty = 0
        for f in range(8):
            p = pos.board[rank * 16 + f]
            if p == ref.EMPTY:
                empty += 1
            else:
                if empty:
                    row += str(empty)
                    empty = 0
                row += p
        if empty:
            row += str(empty)
        rows.append(row)
    cast = "".join(c for c, bit in zip("KQkq", (ref.WK, ref.WQ, ref.BK, ref.BQ)) if pos.castling & bit) or "-"
    ep = "-" if pos.ep < 0 else ref.sq_name(pos.ep)
    return f"{'/'.join(rows)} {'w' if pos.side == ref.WHITE else 'b'} {cast} {ep} 0 1"


def random_positions(seed, starts, games, max_plies, per_game):
    """Play seeded random games and sample positions from them."""
    rng = random.Random(seed)
    out = []
    for start in starts:
        for _ in range(games):
            pos = ref.parse_fen(start.split())
            history = []
            for _ply in range(rng.randint(4, max_plies)):
                moves = ref.legal_moves(pos)
                if not moves:
                    break
                pos = ref.make_move(pos, rng.choice(moves))
                history.append(fen_of(pos))
            if history:
                for _ in range(per_game):
                    out.append(rng.choice(history))
    rng.shuffle(out)
    return out


def write_test(idx, name, lines):
    path = os.path.join(TESTS, f"{idx:03d}_{name}")
    with open(path + ".in", "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(path + ".in", "rb") as f:
        res = subprocess.run([sys.executable, REF], stdin=f, capture_output=True, text=True, check=True)
    with open(path + ".out", "w") as f:
        f.write(res.stdout)
    print(f"{idx:03d}_{name}: {len(lines)} queries")


def main():
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        os.remove(os.path.join(TESTS, f))

    tests = list(HAND)

    tests.append(("published_d1_d2", [f"{p} {d}" for p in (START, KIWIPETE, POS3, POS4, POS4M, POS5, POS6) for d in (1, 2)]))
    tests.append(("published_divide2", [f"{p} divide 2" for p in (KIWIPETE, POS3, POS4, POS5, POS6)]))
    tests.append(("edge_suite_d3", [f"{p} 3" for p, _ in EDGE_SUITE]))
    tests.append(("edge_suite_divide3", [f"{p} divide 3" for p, _ in EDGE_SUITE]))

    all_starts = [START, KIWIPETE, POS3, POS4, POS5, POS6] + [p for p, _ in EDGE_SUITE]
    tests.append(("random_divide1", [f"{p} divide 1" for p in random_positions(1, all_starts, 4, 80, 2)]))
    tests.append(("random_d2", [f"{p} 2" for p in random_positions(2, all_starts, 4, 120, 2)]))
    tests.append(("random_divide2", [f"{p} divide 2" for p in random_positions(3, all_starts, 3, 100, 2)]))
    tests.append(("random_long_games", [f"{p} {'divide ' if i % 2 else ''}2" for i, p in enumerate(random_positions(4, [START, KIWIPETE, POS6], 6, 300, 6))]))
    tests.append(("random_d3", [f"{p} 3" for p in random_positions(5, all_starts, 3, 100, 1)]))
    tests.append(("random_divide3", [f"{p} divide 3" for p in random_positions(6, all_starts, 2, 100, 1)]))
    mixed = random_positions(7, all_starts, 3, 100, 2)
    tests.append(("mixed_queries", [f"{p} {'divide ' if i % 3 == 0 else ''}{1 + i % 3}" for i, p in enumerate(mixed)]))

    tests.append(("published_d3", [f"{p} 3" for p in (START, KIWIPETE, POS3, POS4, POS4M, POS5, POS6)]))
    tests.append(("published_d4", [f"{p} 4" for p in (START, POS3, POS4, POS4M)] + [f"{POS3} 5"]))
    tests.append(("edge_suite_full_depth_a", [f"{p} {d}" for p, d in EDGE_SUITE[:4]]))
    tests.append(("edge_suite_full_depth_b", [f"{p} {d}" for p, d in EDGE_SUITE[4:8]]))
    tests.append(("edge_suite_full_depth_c", [f"{p} {d}" for p, d in EDGE_SUITE[8:]]))
    tests.append(("kiwipete_divide4", [f"{KIWIPETE} divide 4"]))
    tests.append(("pos5_pos6_d4", [f"{POS5} 4", f"{POS6} 4"]))
    tests.append(("startpos_d5", [f"{START} 5"]))
    tests.append(("pos3_d6", [f"{POS3} 6"]))
    tests.append(("pos4_d5", [f"{POS4} 5"]))
    tests.append(("many_d3", [f"{p} 3" for p in random_positions(8, all_starts, 4, 100, 2)]))

    for i, (name, lines) in enumerate(tests, 1):
        write_test(i, name, lines)


if __name__ == "__main__":
    main()
