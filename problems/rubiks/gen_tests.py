#!/usr/bin/env python3
"""Generate tests/*.in and tests/*.out for the `rubiks` problem.

Hand-written edge cases and well-known patterns are embedded as literals;
random scrambles use fixed seeds. Each .out file holds the reference
solver's solution, which is only one of many valid answers: verify.py checks
any submitted solution against a cube model directly.
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")
REF = os.path.join(HERE, "reference", "main.py")

ALL_MOVES = [f + s for f in "UDLRFB" for s in ("", "2", "'")]


def random_scramble(rng, n):
    """n random moves with no two consecutive moves on the same face."""
    moves = []
    last = None
    while len(moves) < n:
        m = rng.choice(ALL_MOVES)
        if m[0] == last:
            continue
        moves.append(m)
        last = m[0]
    return " ".join(moves)


SEXY6 = " ".join(["R U R' U'"] * 6)
SUPERFLIP = "U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2"

cases = [
    ("001_empty_scramble", "\n"),
    ("002_single_move", "R\n"),
    ("003_single_prime", "F'\n"),
    ("004_single_double", "U2\n"),
    ("005_move_then_inverse", "R R'\n"),
    ("006_four_quarter_turns", "L L L L\n"),
    ("007_sexy_move_six_times", SEXY6 + "\n"),
    ("008_two_moves", "R U\n"),
    ("009_three_moves", "F R U'\n"),
    ("010_all_eighteen_moves", " ".join(ALL_MOVES) + "\n"),
    ("011_opposite_faces", "U D' U2 D B F' B2 F\n"),
    ("012_multiple_lines_mixed", "R\n\nF R U'\nL2 D' B\n" + SEXY6 + "\n\nU\n"),
    ("013_no_trailing_newline", "B' L2 D"),
    ("014_trailing_empty_scramble", "R U\n\n"),
    ("015_superflip", SUPERFLIP + "\n"),
    ("016_checkerboard", "U2 D2 F2 B2 L2 R2\n"),
    ("017_cube_in_cube", "F L F U' R U F2 L2 U' L' B D' B' L2 U\n"),
    ("018_six_spot", "U D' R L' F B' U D'\n"),
    ("019_t_perm", "R U R' U' R' F R2 U' R' U' R U R' F'\n"),
    ("020_superflip_composed", SUPERFLIP + " " + "U2 D2 F2 B2 L2 R2" + "\n"),
]

rng = random.Random(20260920)
for n in (5, 10, 15, 20):
    cases.append((f"{len(cases) + 1:03d}_random_{n}", random_scramble(rng, n) + "\n"))
for tag in "abcde":
    cases.append((f"{len(cases) + 1:03d}_random_25_{tag}", random_scramble(rng, 25) + "\n"))
for tag in "ab":
    body = "".join(random_scramble(rng, 25) + "\n" for _ in range(10))
    cases.append((f"{len(cases) + 1:03d}_batch_10x25_{tag}", body))
cases.append((f"{len(cases) + 1:03d}_long_scramble_200", random_scramble(rng, 200) + "\n"))
cases.append((f"{len(cases) + 1:03d}_long_scramble_1000", random_scramble(rng, 1000) + "\n"))
body = "".join(random_scramble(rng, rng.randint(0, 40)) + "\n" for _ in range(20))
cases.append((f"{len(cases) + 1:03d}_batch_20_mixed_lengths", body))
body = "".join(random_scramble(rng, 25) + "\n" for _ in range(25))
cases.append((f"{len(cases) + 1:03d}_batch_25x25", body))


def main():
    os.makedirs(TESTS, exist_ok=True)
    for old in os.listdir(TESTS):
        if old.endswith(".in") or old.endswith(".out"):
            os.remove(os.path.join(TESTS, old))
    for name, data in cases:
        in_path = os.path.join(TESTS, name + ".in")
        with open(in_path, "w", encoding="utf-8") as f:
            f.write(data)
        res = subprocess.run([sys.executable, REF], input=data.encode(), capture_output=True, check=True)
        with open(os.path.join(TESTS, name + ".out"), "wb") as f:
            f.write(res.stdout)
        print(name)


if __name__ == "__main__":
    main()
