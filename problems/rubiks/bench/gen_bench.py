#!/usr/bin/env python3
"""Generate the `rubiks` performance benchmark inputs (bench/*.in) and their
expected outputs (bench/*.out, produced by the reference solver).

Every input uses the spec's maximum of 100 scrambles; verify.py checks any
valid solution, so the .out files are just one accepted answer.

`--long` writes the long tier to bench-long/ instead: the same three inputs
with many more scrambles each (see NOTES.md). The reference solver is too slow
for those, so `--long` requires `--solver CMD` (a compiled implementation's
run.sh); its output becomes the .out file only after verify.py accepts it.
"""
import argparse
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
sys.path.insert(0, PROBLEM)
from gen_tests import SEXY6, SUPERFLIP, random_scramble  # noqa: E402

REF = os.path.join(PROBLEM, "reference", "main.py")
N_LINES = 100
# Long tier: scrambles per input (the short tier always uses N_LINES).
LONG_LINES = {"001": 900_000, "002": 2_000, "003": 980_000}
VERIFY = os.path.join(PROBLEM, "verify.py")

PATTERNS = [
    SUPERFLIP,
    SUPERFLIP + " U2 D2 F2 B2 L2 R2",
    "U2 D2 F2 B2 L2 R2",
    "F L F U' R U F2 L2 U' L' B D' B' L2 U",
    "U D' R L' F B' U D'",
    "R U R' U' R' F R2 U' R' U' R U R' F'",
    SEXY6,
    "R2 U R U R' U' R' U' R' U R'",
    "F U' F2 D' B U R' F' L D' R' U' L U B' D2 R' F U2 D2",
    "R' U2 R U R' U2 L U' R U L'",
]


def random_states(rng, n=N_LINES):
    return [random_scramble(rng, 25) for _ in range(n)]


def long_scrambles(rng, n=N_LINES):
    return [random_scramble(rng, 1000) for _ in range(n)]


def mixed(rng, n=N_LINES):
    # The mix is defined per 100 lines; the long tier repeats it n/100 times.
    k = n // N_LINES
    lines = list(PATTERNS) * k
    # Superflip followed by a few random moves: states close to the deepest
    # region of the cube group, with every edge misoriented for phase 1.
    for _ in range(40 * k):
        lines.append(SUPERFLIP + " " + random_scramble(rng, rng.randint(1, 6)))
    for _ in range(30 * k):
        lines.append(random_scramble(rng, 25))
    for _ in range(15 * k):
        lines.append(random_scramble(rng, rng.randint(1, 12)))
    for _ in range(5 * k):
        lines.append(random_scramble(rng, rng.randint(100, 400)))
    lines = lines[: n - 2 * k] + [""] * (2 * k)
    rng.shuffle(lines)
    return lines


CASES = [
    ("001_random_states_100x25", random_states, 20261011),
    ("002_long_scrambles_100x1000", long_scrambles, 20261012),
    ("003_mixed_patterns_superflip_100", mixed, 20261013),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--long", action="store_true", help="write the long tier to bench-long/")
    ap.add_argument("--solver", help="command whose verified output becomes the long tier's .out")
    args = ap.parse_args()
    out_dir = HERE
    if args.long:
        if not args.solver:
            ap.error("--long needs --solver (the reference is too slow for the long tier)")
        out_dir = os.path.join(PROBLEM, "bench-long")
        os.makedirs(out_dir, exist_ok=True)
    for name, fn, seed in CASES:
        n = LONG_LINES[name[:3]] if args.long else N_LINES
        lines = fn(random.Random(seed), n)
        assert len(lines) == n
        assert all(len(l.split()) <= 1000 for l in lines)
        data = "".join(l + "\n" for l in lines)
        in_path = os.path.join(out_dir, name + ".in")
        out_path = os.path.join(out_dir, name + ".out")
        with open(in_path, "w", encoding="utf-8") as f:
            f.write(data)
        if args.long:
            res = subprocess.run(args.solver, shell=True, input=data.encode(), capture_output=True,
                                 check=True, cwd=PROBLEM)
            with open(out_path, "wb") as f:
                f.write(res.stdout)
            subprocess.run([sys.executable, VERIFY, in_path, out_path], check=True)
        else:
            res = subprocess.run([sys.executable, REF], input=data.encode(), capture_output=True, check=True)
            with open(out_path, "wb") as f:
                f.write(res.stdout)
        print(name)


if __name__ == "__main__":
    main()
