#!/usr/bin/env python3
"""Generate tests/*.in and tests/*.out for the `sat` problem.

Hand-written edge cases are embedded as literals; structured families
(pigeonhole, graph colouring, parity chains) and random 3-SAT near the
satisfiability threshold are produced with fixed seeds. Each .out file holds
the reference solver's verdict ("SAT" or "UNSAT") on its own line; for SAT
instances the recorded assignment is only one of possibly many valid ones,
and verify.py checks any assignment against the clauses directly.
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")
REF = os.path.join(HERE, "reference", "main.py")


def cnf(nvars, clauses, comment=None):
    lines = []
    if comment:
        lines.append("c " + comment)
    lines.append(f"p cnf {nvars} {len(clauses)}")
    for c in clauses:
        lines.append(" ".join(map(str, c)) + " 0")
    return "\n".join(lines) + "\n"


# -- structured families --------------------------------------------------

def pigeonhole(holes):
    """PHP(n): n+1 pigeons into n holes, each pigeon in some hole, no hole
    holding two pigeons. Unsatisfiable, and exponentially hard for resolution."""
    pigeons = holes + 1

    def var(i, j):
        return i * holes + j + 1

    clauses = [[var(i, j) for j in range(holes)] for i in range(pigeons)]
    for j in range(holes):
        for i in range(pigeons):
            for k in range(i + 1, pigeons):
                clauses.append([-var(i, j), -var(k, j)])
    return cnf(pigeons * holes, clauses, f"pigeonhole PHP({holes}): {pigeons} pigeons, {holes} holes")


def coloring(nverts, edges, k, comment):
    """Proper k-colouring of a graph: each vertex gets at least and at most one
    colour, adjacent vertices differ."""

    def var(v, c):
        return v * k + c + 1

    clauses = []
    for v in range(nverts):
        clauses.append([var(v, c) for c in range(k)])
        for c1 in range(k):
            for c2 in range(c1 + 1, k):
                clauses.append([-var(v, c1), -var(v, c2)])
    for (a, b) in edges:
        for c in range(k):
            clauses.append([-var(a, c), -var(b, c)])
    return cnf(nverts * k, clauses, comment)


def complete_graph(n):
    return [(i, j) for i in range(n) for j in range(i + 1, n)]


def petersen():
    outer = [(i, (i + 1) % 5) for i in range(5)]
    spokes = [(i, i + 5) for i in range(5)]
    inner = [(5 + i, 5 + (i + 2) % 5) for i in range(5)]
    return outer + spokes + inner


def random_planted_colorable(n, k, edge_prob, seed):
    """Random graph whose edges never join vertices of the same hidden colour,
    so it is k-colourable by construction."""
    r = random.Random(seed)
    colour = [r.randrange(k) for _ in range(n)]
    edges = []
    for i in range(n):
        for j in range(i + 1, n):
            if colour[i] != colour[j] and r.random() < edge_prob:
                edges.append((i, j))
    return edges


def random_graph(n, edge_prob, seed):
    r = random.Random(seed)
    return [(i, j) for i in range(n) for j in range(i + 1, n) if r.random() < edge_prob]


def xor3(a, b, c):
    """Clauses for a XOR b = c."""
    return [[-a, -b, -c], [a, b, -c], [a, -b, c], [-a, b, c]]


def parity_chain(n, target, two_chains):
    """Linear XOR chain forcing x1 ^ ... ^ xn = target through auxiliaries
    s2..sn (s_i = s_{i-1} ^ x_i). With two_chains, a second chain over the
    same x variables forces the opposite parity, giving an UNSAT instance."""
    clauses = []
    nv = n
    for tgt in ([target, 1 - target] if two_chains else [target]):
        prev = 1
        for i in range(2, n + 1):
            nv += 1
            clauses.extend(xor3(prev, i, nv))
            prev = nv
        clauses.append([prev if tgt else -prev])
    what = "two contradictory" if two_chains else "one"
    return cnf(nv, clauses, f"parity: {what} XOR chain(s) over {n} variables")


def random_3sat(n, ratio, seed):
    r = random.Random(seed)
    m = round(ratio * n)
    clauses = []
    for _ in range(m):
        vs = r.sample(range(1, n + 1), 3)
        clauses.append([v if r.random() < 0.5 else -v for v in vs])
    return cnf(n, clauses, f"random 3-SAT n={n} m={m} seed={seed}")


def long_clause_chain(n):
    """One clause of n literals plus units falsifying all but the last, so the
    watch scheme must walk the whole clause to find the forced literal."""
    clauses = [list(range(1, n + 1))]
    clauses.extend([[-i] for i in range(1, n)])
    return cnf(n, clauses, f"one {n}-literal clause with {n - 1} units")


# -- hand-written edge cases ------------------------------------------------

HAND = [
    ("empty_formula", "p cnf 0 0\n"),
    ("no_clauses", "c three variables, nothing constrains them\np cnf 3 0\n"),
    ("empty_clause", "p cnf 2 1\n0\n"),
    ("single_unit", "p cnf 1 1\n1 0\n"),
    ("unit_conflict", "p cnf 1 2\n1 0\n-1 0\n"),
    ("unit_chain", "c unit propagation only: 1 forces 2 forces 3 forces -4 forces 5\n"
                   "p cnf 5 5\n1 0\n-1 2 0\n-2 3 0\n-3 -4 0\n4 5 0\n"),
    ("duplicate_literals", "c duplicated literals inside clauses\np cnf 2 3\n1 1 1 0\n-1 -1 2 2 0\n-2 -2 -1 0\n"),
    ("tautology_only", "c every clause contains x and -x; nothing is constrained\np cnf 3 3\n1 -1 0\n2 -2 3 0\n-3 1 3 0\n"),
    ("tautology_and_conflict", "c the tautological clause does not rescue the contradiction\n"
                               "p cnf 2 4\n1 -1 2 0\n1 0\n-1 2 0\n-1 -2 0\n"),
    ("messy_layout", "c comments, clauses spanning lines, several clauses per line,\n"
                     "c tabs and repeated spaces, no newline at end of file\n"
                     "p  cnf\t4  5\n"
                     "1 2\n"
                     "  3 0 -1\n"
                     "c a comment in the middle of a clause\n"
                     "-2 0 -3 4 0\t-4\n"
                     "-1 0 2 -3 0"),
    ("unused_variables", "c variables 2 and 5 never appear but must still be assigned\np cnf 5 3\n1 3 0\n-1 4 0\n-3 -4 0\n"),
    ("all_eight_clauses", "c all 8 clauses over 3 variables: unsatisfiable\np cnf 3 8\n"
                          "1 2 3 0\n1 2 -3 0\n1 -2 3 0\n1 -2 -3 0\n-1 2 3 0\n-1 2 -3 0\n-1 -2 3 0\n-1 -2 -3 0\n"),
    ("seven_of_eight", "c 7 of the 8 clauses over 3 variables: exactly one model (1 2 -3)\np cnf 3 7\n"
                       "1 2 3 0\n1 2 -3 0\n1 -2 3 0\n1 -2 -3 0\n-1 2 3 0\n-1 2 -3 0\n-1 -2 -3 0\n"),
    ("needs_backtracking", "c unit propagation alone does nothing; a wrong first guess must be undone\np cnf 4 6\n"
                           "1 2 0\n-1 3 0\n-1 -3 0\n-2 4 0\n-2 -4 1 0\n3 4 0\n"),
    ("comment_forms", "c\n"
                      "   c indented comment\n"
                      "cglued comment, no space after the c\n"
                      "\n"
                      "  p cnf 3 3  \n"
                      "\n"
                      "1 -2 0\n"
                      "c\n"
                      "\t \n"
                      "   -1 3 0\n"
                      "   c another indented comment\n"
                      "2 3 0\n"
                      "c trailing comment after the last clause\n"),
    ("tautology_rescue", "c the tautological first clause must count as satisfied, not be stripped to (2)\n"
                         "p cnf 3 4\n1 1 -1 -1 2 0\n-2 0\n1 3 0\n-1 3 0\n"),
    ("wide_units", "c 64 variables, few clauses: the assignment line must still list all 64\np cnf 64 4\n"
                   "-64 0\n1 0\n1 64 0\n-1 -64 33 0\n"),
]


def generated():
    cases = []
    cases.append(("php2", pigeonhole(2)))
    cases.append(("parity_sat_20", parity_chain(20, 1, False)))
    cases.append(("parity_unsat_16", parity_chain(16, 0, True)))
    cases.append(("k4_3colors_unsat", coloring(4, complete_graph(4), 3, "K4 with 3 colours (UNSAT)")))
    cases.append(("k4_4colors_sat", coloring(4, complete_graph(4), 4, "K4 with 4 colours (SAT)")))
    cases.append(("petersen_2colors_unsat", coloring(10, petersen(), 2, "Petersen graph with 2 colours (UNSAT)")))
    cases.append(("petersen_3colors_sat", coloring(10, petersen(), 3, "Petersen graph with 3 colours (SAT)")))
    cases.append(("long_clause_1000", long_clause_chain(1000)))
    for n in (4, 5, 6, 7, 8):
        cases.append((f"php{n}", pigeonhole(n)))
    cases.append(("color_planted_40v_3c", coloring(40, random_planted_colorable(40, 3, 0.25, 101), 3,
                                                   "random 40-vertex graph, planted 3-colouring (SAT)")))
    cases.append(("color_random_25v_3c", coloring(25, random_graph(25, 0.4, 202), 3,
                                                  "random 25-vertex graph, p=0.4, 3 colours")))
    cases.append(("color_planted_80v_4c", coloring(80, random_planted_colorable(80, 4, 0.2, 303), 4,
                                                   "random 80-vertex graph, planted 4-colouring (SAT)")))
    cases.append(("color_random_30v_4c", coloring(30, random_graph(30, 0.6, 404), 4,
                                                  "random 30-vertex graph, p=0.6, 4 colours")))
    cases.append(("parity_unsat_60", parity_chain(60, 1, True)))
    cases.append(("rand3_easy_2000v", random_3sat(2000, 3.0, 7)))
    # Random 3-SAT at the phase transition; seeds chosen so both verdicts appear.
    for n, seed in [(50, 11), (50, 12), (75, 21), (75, 22), (100, 31), (100, 32),
                    (125, 41), (125, 42), (150, 51), (150, 52), (175, 61), (175, 62),
                    (200, 1), (200, 2), (200, 5)]:
        cases.append((f"rand3_{n}v_s{seed}", random_3sat(n, 4.26, seed)))
    return cases


def main():
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        os.remove(os.path.join(TESTS, f))
    cases = HAND + generated()
    for idx, (name, text) in enumerate(cases, start=1):
        base = f"{idx:03d}_{name}"
        with open(os.path.join(TESTS, base + ".in"), "w") as f:
            f.write(text)
        proc = subprocess.run([sys.executable, REF], input=text, capture_output=True, text=True, check=True)
        with open(os.path.join(TESTS, base + ".out"), "w") as f:
            f.write(proc.stdout)
        print(base, proc.stdout.split("\n", 1)[0])
    print(f"{len(cases)} tests written")


if __name__ == "__main__":
    main()
