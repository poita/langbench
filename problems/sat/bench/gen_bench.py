#!/usr/bin/env python3
"""Generate the performance benchmark inputs for the `sat` problem.

Writes bench/NNN_name.in and bench/NNN_name.out in the same layout as tests/,
so `run_tests.py sat --tests-dir problems/sat/bench` works. All instances are
deterministic (fixed seeds) and stay within the limits in SPEC.md
(V <= 2000, C <= 6000, <= 18000 literal occurrences, < 128 KB).

Expected outputs come from the Python reference solver; pass --no-ref to write
only the inputs (the .out files are then left untouched).
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
REF = os.path.join(PROBLEM, "reference", "main.py")
sys.path.insert(0, PROBLEM)

import gen_tests as g  # noqa: E402


def to_cnf(nvars, clauses, comments):
    lines = ["c " + c for c in comments]
    lines.append(f"p cnf {nvars} {len(clauses)}")
    for c in clauses:
        lines.append(" ".join(map(str, c)) + " 0")
    return "\n".join(lines) + "\n"


def random_3sat_clauses(n, ratio, seed):
    r = random.Random(seed)
    clauses = []
    for _ in range(round(ratio * n)):
        vs = r.sample(range(1, n + 1), 3)
        clauses.append([v if r.random() < 0.5 else -v for v in vs])
    return clauses


def coloring_clauses(nverts, edges, k):
    def var(v, c):
        return v * k + c + 1

    clauses = []
    for v in range(nverts):
        clauses.append([var(v, c) for c in range(k)])
        for c1 in range(k):
            for c2 in range(c1 + 1, k):
                clauses.append([-var(v, c1), -var(v, c2)])
    for a, b in edges:
        for c in range(k):
            clauses.append([-var(a, c), -var(b, c)])
    return nverts * k, clauses


def parity_clauses(n, target):
    """x1 ^ ... ^ xn = target via auxiliaries s_i = s_{i-1} ^ x_i."""
    clauses = []
    nv = n
    prev = 1
    for i in range(2, n + 1):
        nv += 1
        clauses.extend(g.xor3(prev, i, nv))
        prev = nv
    clauses.append([prev if target else -prev])
    return nv, clauses


def rand3_unsat():
    """Random 3-SAT at the phase transition, larger than any public test."""
    n, seed = 225, 4
    clauses = random_3sat_clauses(n, 4.26, seed)
    return to_cnf(n, clauses, [f"random 3-SAT n={n} m={len(clauses)} ratio=4.26 seed={seed} (UNSAT)"])


def color4_unsat():
    """4-colouring of a G(n, p) random graph just above the 4-colourability
    threshold (average degree 8.4)."""
    n, k, deg, seed = 150, 4, 8.4, 1
    edges = g.random_graph(n, deg / (n - 1), seed)
    nv, clauses = coloring_clauses(n, edges, k)
    return to_cnf(nv, clauses, [f"{k}-colouring of random graph n={n} avg-degree={deg} seed={seed} "
                                f"edges={len(edges)} (UNSAT)"])


def mixed_sat(rand_seeds=(6, 8, 9, 10), colour_seeds=(2,), parity_sizes=(40,), shuffle_seed=2026):
    """Several independent satisfiable subproblems of different kinds in one
    formula, with variables renumbered and clauses shuffled so the components
    are interleaved: near-threshold random 3-SAT instances, planted
    3-colourings near their threshold, and XOR parity chains."""
    parts = []
    for seed in rand_seeds:
        # These seeds give satisfiable 200-variable instances at ratio 4.2.
        parts.append((200, random_3sat_clauses(200, 4.2, seed)))
    n, k, deg = 200, 3, 4.6
    nedges = []
    for seed in colour_seeds:
        edges = g.random_planted_colorable(n, k, deg / ((n - 1) * (1 - 1 / k)), seed)
        nedges.append(len(edges))
        parts.append(coloring_clauses(n, edges, k))
    for size in parity_sizes:
        parts.append(parity_clauses(size, 1))

    clauses = []
    off = 0
    for nv, cls in parts:
        clauses.extend([[(abs(l) + off) * (1 if l > 0 else -1) for l in c] for c in cls])
        off += nv
    r = random.Random(shuffle_seed)
    perm = list(range(1, off + 1))
    r.shuffle(perm)
    clauses = [[perm[abs(l) - 1] * (1 if l > 0 else -1) for l in c] for c in clauses]
    r.shuffle(clauses)
    if len(rand_seeds) == 4 and len(colour_seeds) == 1 and len(parity_sizes) == 1:
        comments = [
            "mixed satisfiable workload: 4 x random 3-SAT n=200 ratio=4.2 (seeds %s)," % ",".join(map(str, rand_seeds)),
            f"planted 3-colouring n=200 avg-degree=4.6 seed={colour_seeds[0]} ({nedges[0]} edges), "
            f"XOR chain over {parity_sizes[0]} vars;",
            f"variables permuted and clauses shuffled (seed {shuffle_seed}) (SAT)"]
    else:
        comments = [
            "mixed satisfiable workload: %d x random 3-SAT n=200 ratio=4.2 (seeds %s),"
            % (len(rand_seeds), ",".join(map(str, rand_seeds))),
            "%d x planted 3-colouring n=200 avg-degree=4.6 (seeds %s, %d edges in total), %d XOR chains over %s vars;"
            % (len(colour_seeds), ",".join(map(str, colour_seeds)), sum(nedges), len(parity_sizes),
               "/".join(map(str, parity_sizes))),
            f"variables permuted and clauses shuffled (seed {shuffle_seed}) (SAT)"]
    return to_cnf(off, clauses, comments)


CASES = [
    ("001_rand3_unsat_225v", rand3_unsat),
    ("002_color4_unsat_150v", color4_unsat),
    ("003_mixed_components_sat", mixed_sat),
]


# Long tier (../bench-long): the same three kinds of instance, made harder.
# 001 and 002 are single larger or harder UNSAT instances (seeds picked so the
# compiled solvers need several seconds); 003 has 14 times as many satisfiable
# components. The random 3-SAT seeds below give satisfiable 200-variable
# instances at ratio 4.2.
LONG_RAND_SEEDS = (6, 8, 9, 10, 11, 13, 14, 15, 17, 18, 21, 22, 23, 24, 25, 26, 27, 28, 34, 35, 36, 38,
                   39, 40, 41, 45, 46, 47, 48, 51, 52, 53, 54, 55, 56, 57, 59, 60, 61, 62, 63, 66, 67, 68,
                   70, 71, 72, 73, 74, 75, 79, 80, 81, 82, 83, 84)
LONG_COMPONENTS = 14


def rand3_unsat_long():
    n, seed = 275, 6
    clauses = random_3sat_clauses(n, 4.26, seed)
    return to_cnf(n, clauses, [f"random 3-SAT n={n} m={len(clauses)} ratio=4.26 seed={seed} (UNSAT)"])


def color4_unsat_long():
    n, k, deg, seed = 150, 4, 8.4, 15
    edges = g.random_graph(n, deg / (n - 1), seed)
    nv, clauses = coloring_clauses(n, edges, k)
    return to_cnf(nv, clauses, [f"{k}-colouring of random graph n={n} avg-degree={deg} seed={seed} "
                                f"edges={len(edges)} (UNSAT)"])


def mixed_sat_long():
    k = LONG_COMPONENTS
    return mixed_sat(rand_seeds=LONG_RAND_SEEDS[:4 * k], colour_seeds=tuple(range(2, 2 + k)),
                     parity_sizes=(40,) * k, shuffle_seed=12026)


LONG_CASES = [
    ("001_rand3_unsat_225v", rand3_unsat_long),
    ("002_color4_unsat_150v", color4_unsat_long),
    ("003_mixed_components_sat", mixed_sat_long),
]
LONG_DIR = os.path.join(PROBLEM, "bench-long")


def check_limits(name, text, long=False):
    nv, clauses = g_parse(text)
    lits = sum(len(c) for c in clauses)
    if long:
        assert nv <= 25000 and len(clauses) <= 100000 and lits <= 250000, (name, nv, len(clauses), lits)
        assert max(len(c) for c in clauses) <= 1000 and len(text.encode()) < 2 * 1024 * 1024, name
    else:
        assert nv <= 2000 and len(clauses) <= 6000 and lits <= 18000, (name, nv, len(clauses), lits)
        assert max(len(c) for c in clauses) <= 1000 and len(text.encode()) < 128 * 1024, name
    return nv, len(clauses), lits


def g_parse(text):
    nv = 0
    toks = []
    for line in text.split("\n"):
        s = line.strip()
        if not s or s[0] == "c":
            continue
        if s[0] == "p":
            nv = int(s.split()[2])
            continue
        toks.extend(map(int, s.split()))
    clauses, cur = [], []
    for t in toks:
        if t == 0:
            clauses.append(cur)
            cur = []
        else:
            cur.append(t)
    return nv, clauses


def main():
    use_ref = "--no-ref" not in sys.argv[1:]
    long = "--long" in sys.argv[1:]
    out_dir = LONG_DIR if long else HERE
    os.makedirs(out_dir, exist_ok=True)
    only = [a for a in sys.argv[1:] if not a.startswith("--")]
    for name, make in (LONG_CASES if long else CASES):
        if only and not any(name.startswith(o) for o in only):
            continue
        text = make()
        nv, nc, nl = check_limits(name, text, long)
        with open(os.path.join(out_dir, name + ".in"), "w") as f:
            f.write(text)
        line = f"{name}: V={nv} C={nc} literals={nl} bytes={len(text)}"
        if use_ref:
            proc = subprocess.run([sys.executable, REF], input=text, capture_output=True, text=True, check=True)
            with open(os.path.join(out_dir, name + ".out"), "w") as f:
                f.write(proc.stdout)
            line += " " + proc.stdout.split("\n", 1)[0]
        print(line, flush=True)


if __name__ == "__main__":
    main()
