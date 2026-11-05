#!/usr/bin/env python3
"""Verifier for the `sat` problem.

Usage: verify.py <input.in> <actual.out> [<expected.out>]

A "SAT" answer is accepted only if its assignment line is exactly the tokens
`1` or `-1`, `2` or `-2`, ..., `V` or `-V`, then `0`, separated by single
spaces, and the assignment satisfies every clause. An "UNSAT" answer is
accepted only if the expected output (the reference verdict) is also UNSAT.
Trailing whitespace on a line and trailing blank lines are tolerated; nothing
else is. Exit 0 on pass; otherwise print a reason and exit 1.
"""
import sys


def parse_dimacs(text):
    nvars = None
    tokens = []
    for line in text.split("\n"):
        s = line.strip()
        if not s or s[0] == "c":
            continue
        if s[0] == "p":
            nvars = int(s.split()[2])
            continue
        tokens.extend(s.split())
    clauses = []
    cur = []
    for t in tokens:
        x = int(t)
        if x == 0:
            clauses.append(cur)
            cur = []
        else:
            cur.append(x)
    return (nvars or 0), clauses


def fail(msg):
    print(msg)
    sys.exit(1)


def main():
    in_path, actual_path = sys.argv[1], sys.argv[2]
    expected_path = sys.argv[3] if len(sys.argv) > 3 else None

    with open(in_path, encoding="utf-8") as f:
        nvars, clauses = parse_dimacs(f.read())
    with open(actual_path, encoding="utf-8", errors="replace") as f:
        lines = [l.rstrip() for l in f.read().replace("\r\n", "\n").split("\n")]
    while lines and lines[-1] == "":
        lines.pop()

    expected = None
    if expected_path:
        with open(expected_path, encoding="utf-8") as f:
            expected = f.readline().strip()

    if not lines:
        fail("empty output; expected SAT or UNSAT")
    verdict = lines[0]

    if verdict == "UNSAT":
        if len(lines) != 1:
            fail(f"UNSAT must be the only output line; got {len(lines)} lines")
        if expected is None:
            fail("cannot accept UNSAT without the expected output to compare against")
        if expected != "UNSAT":
            fail("claimed UNSAT but the formula is satisfiable")
        return

    if verdict != "SAT":
        fail(f"first line must be exactly SAT or UNSAT; got {verdict!r}")
    if len(lines) != 2:
        fail(f"SAT must be followed by exactly one assignment line; got {len(lines)} lines")
    if expected == "UNSAT":
        fail("claimed SAT but the formula is unsatisfiable")

    toks = lines[1].split(" ")
    if len(toks) != nvars + 1:
        fail(f"assignment line must have {nvars} literals followed by 0, separated by single spaces; "
             f"got {len(toks)} tokens")
    if toks[-1] != "0":
        fail(f"assignment line must end with the token 0; got {toks[-1]!r}")
    truth = [False] * (nvars + 1)
    for i in range(nvars):
        t = toks[i]
        if t == str(i + 1):
            truth[i + 1] = True
        elif t == str(-(i + 1)):
            truth[i + 1] = False
        else:
            fail(f"token {i + 1} must be exactly {i + 1} or -{i + 1}; got {t!r}")

    for idx, clause in enumerate(clauses):
        ok = False
        for lit in clause:
            if abs(lit) > nvars:
                fail(f"clause {idx + 1} references variable {abs(lit)} beyond V={nvars}")
            if truth[abs(lit)] == (lit > 0):
                ok = True
                break
        if not ok:
            fail(f"clause {idx + 1} ({' '.join(map(str, clause))} 0) is falsified by the assignment")


if __name__ == "__main__":
    main()
