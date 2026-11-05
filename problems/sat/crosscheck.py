#!/usr/bin/env python3
"""Cross-check the recorded SAT/UNSAT verdicts in tests/*.out with methods
independent of the reference CDCL solver.

  * Exhaustive truth-table evaluation for V <= 22 (each variable's column of
    the 2^V-row truth table is a big integer; a clause is an OR of columns and
    the formula is the AND of clauses, so the formula is satisfiable iff the
    resulting integer is non-zero).
  * A plain recursive DPLL (unit propagation + pure literals + most-frequent
    variable branching) for larger instances, bounded by a node budget.
  * pycosat, when importable (run under an interpreter that has it).

Usage: crosscheck.py [--budget N]   (run from anywhere; reads tests/ next to it)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")

sys.setrecursionlimit(100000)


def parse_dimacs(text):
    nvars = 0
    tokens = []
    for line in text.split("\n"):
        s = line.strip()
        if not s or s[0] == "c":
            continue
        if s[0] == "p":
            nvars = int(s.split()[2])
            continue
        tokens.extend(s.split())
    clauses, cur = [], []
    for t in tokens:
        x = int(t)
        if x == 0:
            clauses.append(cur)
            cur = []
        else:
            cur.append(x)
    return nvars, clauses


def truth_table_sat(nvars, clauses):
    rows = 1 << nvars
    full = (1 << rows) - 1
    cols = []
    for i in range(nvars):
        w = 1 << i
        p = ((1 << w) - 1) << w          # pattern of width 2w: w zeros then w ones
        for j in range(i + 1, nvars):
            p |= p << (1 << j)
        cols.append(p)
    formula = full
    for c in clauses:
        cl = 0
        for lit in c:
            col = cols[abs(lit) - 1]
            cl |= col if lit > 0 else (full ^ col)
        formula &= cl
        if formula == 0:
            return False
    return formula != 0


class Budget(Exception):
    pass


def dpll_sat(clauses, budget):
    """Naive DPLL on immutable clause lists; raises Budget when the node
    budget is exhausted."""
    counter = [0]

    def simplify(cls, lit):
        out = []
        for c in cls:
            if lit in c:
                continue
            if -lit in c:
                c = [x for x in c if x != -lit]
                if not c:
                    return None
            out.append(c)
        return out

    def rec(cls):
        counter[0] += 1
        if counter[0] > budget:
            raise Budget()
        while True:
            if not cls:
                return True
            unit = None
            for c in cls:
                if len(c) == 1:
                    unit = c[0]
                    break
            if unit is None:
                break
            cls = simplify(cls, unit)
            if cls is None:
                return False
        freq = {}
        for c in cls:
            for x in c:
                freq[x] = freq.get(x, 0) + 1
        pure = [x for x in freq if -x not in freq]
        if pure:
            for x in pure:
                cls = simplify(cls, x)
                if cls is None:
                    return False
            return rec(cls)
        best = max(freq, key=lambda x: freq[x] + freq.get(-x, 0))
        for lit in (best, -best):
            s = simplify(cls, lit)
            if s is not None and rec(s):
                return True
        return False

    return rec([list(dict.fromkeys(c)) for c in clauses])


def main():
    budget = 200000
    if "--budget" in sys.argv:
        budget = int(sys.argv[sys.argv.index("--budget") + 1])
    try:
        import pycosat
    except ImportError:
        pycosat = None
    print("pycosat:", "available" if pycosat else "not available")
    mismatches = 0
    for name in sorted(os.listdir(TESTS)):
        if not name.endswith(".in"):
            continue
        base = name[:-3]
        with open(os.path.join(TESTS, name)) as f:
            nvars, clauses = parse_dimacs(f.read())
        with open(os.path.join(TESTS, base + ".out")) as f:
            expected = f.readline().strip() == "SAT"
        results = []
        if nvars <= 22:
            results.append(("truth-table", truth_table_sat(nvars, clauses)))
        else:
            try:
                results.append(("dpll", dpll_sat(clauses, budget)))
            except Budget:
                results.append(("dpll", None))
        if pycosat is not None:
            results.append(("pycosat", pycosat.solve(clauses) != "UNSAT"))
        parts = []
        for method, r in results:
            if r is None:
                parts.append(f"{method}=skipped")
            else:
                ok = r == expected
                mismatches += 0 if ok else 1
                parts.append(f"{method}={'SAT' if r else 'UNSAT'}{'' if ok else ' MISMATCH'}")
        print(f"{base:32s} expected={'SAT' if expected else 'UNSAT':5s} " + " ".join(parts))
    print("mismatches:", mismatches)
    return 1 if mismatches else 0


if __name__ == "__main__":
    sys.exit(main())
