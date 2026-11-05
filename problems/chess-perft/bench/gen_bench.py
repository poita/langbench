#!/usr/bin/env python3
"""Generate the chess-perft performance benchmark inputs and expected outputs.

Positions come from seeded random games played with the reference move
generator (via gen_tests.py). Each query's output is produced by running the
reference's own query logic, and queries are accepted greedily until the file
reaches its leaf-node budget, so every file stays within SPEC.md's limits
(at most 160 queries, about 20 million leaf nodes per file, no single query
above about 16 million leaves, depth 7 only with three pieces).
"""
import importlib.util
import io
import os
import random
import sys

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)

spec = importlib.util.spec_from_file_location("gen_tests", os.path.join(PROBLEM, "gen_tests.py"))
gt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gt)
ref = gt.ref

FILE_BUDGET = 19_500_000
MAX_QUERIES = 160


def run_reference(line):
    """Return (output text, leaf total) for one query using the reference main()."""
    old_in, old_out = sys.stdin, sys.stdout
    sys.stdin, sys.stdout = io.StringIO(line + "\n"), io.StringIO()
    try:
        ref.main()
        text = sys.stdout.getvalue()
    finally:
        sys.stdin, sys.stdout = old_in, old_out
    last = text.strip().splitlines()[-1]
    return text, int(last.split()[-1])


def estimate(fen, depth):
    """Estimate perft(depth) from perft(depth-1) and perft(depth-2) without the full search."""
    pos = ref.parse_fen(fen.split())
    if depth <= 2:
        return ref.perft(pos, depth)
    a = ref.perft(pos, depth - 2)
    b = ref.perft(pos, depth - 1)
    return b * b // max(a, 1)


def piece_count(fen):
    return sum(c.isalpha() for c in fen.split()[0])


def fill(candidates, per_query_cap, budget=FILE_BUDGET):
    """Accept (fen, depth, divide) candidates in order until the leaf budget is used up."""
    lines, outputs, total = [], [], 0
    for fen, depth, divide in candidates:
        if len(lines) >= MAX_QUERIES or total >= budget * 0.98:
            break
        if depth >= 7 and piece_count(fen) > 3:
            continue
        est = estimate(fen, depth)
        if est > per_query_cap or total + est > budget * 1.1:
            continue
        line = f"{fen} {'divide ' if divide else ''}{depth}"
        text, leaves = run_reference(line)
        if leaves == 0 or leaves > per_query_cap or total + leaves > budget:
            continue
        lines.append(line)
        outputs.append(text)
        total += leaves
    return lines, "".join(outputs), total


def write_case(name, lines, output):
    path = os.path.join(HERE, name)
    with open(path + ".in", "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(path + ".out", "w") as f:
        f.write(output)


def sample(seed, starts, games, min_plies, max_plies, per_game, keep=lambda fen: True):
    """Seeded random games; sample positions reached after at least min_plies plies."""
    rng = random.Random(seed)
    out = []
    for start in starts:
        for _ in range(games):
            pos = ref.parse_fen(start.split())
            history = []
            for ply in range(rng.randint(min_plies, max_plies)):
                moves = ref.legal_moves(pos)
                if not moves:
                    break
                pos = ref.make_move(pos, rng.choice(moves))
                if ply + 1 >= min_plies:
                    fen = gt.fen_of(pos)
                    if keep(fen):
                        history.append(fen)
            for _ in range(min(per_game, len(history))):
                out.append(rng.choice(history))
    rng.shuffle(out)
    return out


def middlegames():
    """Ordinary opening/middlegame positions searched to depth 4."""
    starts = [gt.START, gt.KIWIPETE, gt.POS4, gt.POS4M, gt.POS5, gt.POS6]
    pool = sample(101, starts, 12, 6, 30, 1, keep=lambda f: piece_count(f) >= 20)
    cands = [(fen, 4, False) for fen in pool]
    return fill(cands, per_query_cap=8_000_000)


def endgames():
    """Few-piece positions searched deep: low branching, long move sequences."""
    starts = [gt.START, gt.KIWIPETE, gt.POS3, gt.POS6] + [p for p, _ in gt.EDGE_SUITE]
    pool = sample(202, starts, 10, 60, 400, 2, keep=lambda f: 4 <= piece_count(f) <= 11)
    cands = [(fen, 7 if piece_count(fen) <= 3 else (6 if piece_count(fen) <= 8 else 5), False) for fen in pool]
    return fill(cands, per_query_cap=5_000_000)


def mixed():
    """Many positions from every game phase, alternating perft and divide queries."""
    starts = [gt.START, gt.KIWIPETE, gt.POS3, gt.POS4, gt.POS5, gt.POS6] + [p for p, _ in gt.EDGE_SUITE]
    pool = sample(303, starts, 8, 4, 200, 2)
    depth_cycle = (3, 4, 2, 5, 4, 4, 1, 5)
    cands = [(fen, depth_cycle[i % len(depth_cycle)], i % 2 == 1) for i, fen in enumerate(pool)]
    return fill(cands, per_query_cap=2_500_000)


# Long tier: the same three workloads with about 100x the leaf nodes, written to
# ../bench-long. Candidates are accepted on an extrapolated leaf estimate (so
# the reference's full search runs only once per accepted query) and the
# expected output is then produced by the reference.
LONG_DIR = os.path.join(PROBLEM, "bench-long")
LONG_BUDGET = {
    "001_middlegame_d4": 2_000_000_000,
    "002_endgame_deep": 550_000_000,
    "003_mixed_divide_160": 2_000_000_000,
}


def estimate_long(fen, depth):
    """Estimate perft(depth) from perft(depth-3) and perft(depth-2) by extrapolating the branching factor."""
    pos = ref.parse_fen(fen.split())
    if depth <= 3:
        return ref.perft(pos, depth)
    a = ref.perft(pos, depth - 3)
    b = ref.perft(pos, depth - 2)
    return b * b * b // max(a * a, 1)


def fill_long(candidates, per_query_cap, budget, max_queries):
    lines, total = [], 0
    for fen, depth, divide in candidates:
        if len(lines) >= max_queries or total >= budget * 0.98:
            break
        if depth >= 7 and piece_count(fen) > 8:
            continue
        est = estimate_long(fen, depth)
        if est == 0 or est > per_query_cap or total + est > budget:
            continue
        lines.append(f"{fen} {'divide ' if divide else ''}{depth}")
        total += est
    return lines, total


def middlegames_long():
    starts = [gt.START, gt.KIWIPETE, gt.POS4, gt.POS4M, gt.POS5, gt.POS6]
    pool = sample(1101, starts, 200, 6, 30, 1, keep=lambda f: piece_count(f) >= 20)
    cands = [(fen, 4, False) for fen in pool]
    return fill_long(cands, 8_000_000, LONG_BUDGET["001_middlegame_d4"], 1000)


def endgames_long():
    starts = [gt.START, gt.KIWIPETE, gt.POS3, gt.POS6] + [p for p, _ in gt.EDGE_SUITE]
    pool = sample(1202, starts, 40, 60, 400, 2, keep=lambda f: 4 <= piece_count(f) <= 11)
    cands = [(fen, 7 if piece_count(fen) <= 8 else 6, False) for fen in pool]
    return fill_long(cands, 60_000_000, LONG_BUDGET["002_endgame_deep"], 160)


def mixed_long():
    starts = [gt.START, gt.KIWIPETE, gt.POS3, gt.POS4, gt.POS5, gt.POS6] + [p for p, _ in gt.EDGE_SUITE]
    pool = sample(1303, starts, 16, 4, 200, 2)
    depth_cycle = (4, 5, 3, 6, 5, 6, 2, 6)
    cands = [(fen, depth_cycle[i % len(depth_cycle)], i % 2 == 1) for i, fen in enumerate(pool)]
    return fill_long(cands, 200_000_000, LONG_BUDGET["003_mixed_divide_160"], 160)


def main_long(only, dry):
    os.makedirs(LONG_DIR, exist_ok=True)
    for name, build in (
        ("001_middlegame_d4", middlegames_long),
        ("002_endgame_deep", endgames_long),
        ("003_mixed_divide_160", mixed_long),
    ):
        if only and not any(name.startswith(o) for o in only):
            continue
        lines, est = build()
        path = os.path.join(LONG_DIR, name)
        with open(path + ".in", "w") as f:
            f.write("\n".join(lines) + "\n")
        if dry:
            print(f"{name}: {len(lines)} queries, ~{est} leaves (estimated, no output)")
            continue
        old_in, old_out = sys.stdin, sys.stdout
        sys.stdin, sys.stdout = io.StringIO("\n".join(lines) + "\n"), io.StringIO()
        try:
            ref.main()
            text = sys.stdout.getvalue()
        finally:
            sys.stdin, sys.stdout = old_in, old_out
        with open(path + ".out", "w") as f:
            f.write(text)
        print(f"{name}: {len(lines)} queries, ~{est} leaves (estimated)")


def main():
    args = sys.argv[1:]
    if "--long" in args:
        main_long([a for a in args if not a.startswith("--")], "--dry" in args)
        return
    only = args
    for name, build in (
        ("001_middlegame_d4", middlegames),
        ("002_endgame_deep", endgames),
        ("003_mixed_divide_160", mixed),
    ):
        if only and not any(name.startswith(o) for o in only):
            continue
        lines, output, total = build()
        write_case(name, lines, output)
        print(f"{name}: {len(lines)} queries, {total} leaves")


if __name__ == "__main__":
    main()
