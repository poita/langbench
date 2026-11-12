# cdcl-sat

A pure-Python, standard-library-only CDCL SAT solver for DIMACS CNF, with a
reusable library and a small command-line tool.

The solver is MiniSat-style: two watched literals, first-UIP clause learning
with local minimisation, VSIDS branching (double-precision activities, decay
0.95 / 0.999) with phase saving, Luby restarts (`100 * luby(2, i)` conflicts),
and periodic deletion of the lower-activity half of the learnt clauses (binary
clauses are kept). Input clauses are simplified at the root (duplicates,
tautologies, satisfied clauses, false literals; units are propagated).

## Layout

```
src/cdcl_sat/
    dimacs.py   DIMACS parsing and SAT/UNSAT output formatting
    solver.py   Solver (clause database, propagation, analysis, search)
    heap.py     indexed max-heap used for VSIDS
    luby.py     Luby restart sequence
    cli.py      command-line entry point
tests/          pytest suite
build.sh        byte-compiles the sources (no real build step)
run.sh          runs the CLI (sets PYTHONPATH to src/)
```

## Build

Pure Python; there is nothing to compile.

```
./build.sh                 # syntax-checks the sources
pip install -e .[test]     # optional: install the package and pytest
```

## Command line

Reads DIMACS CNF on standard input and prints either `UNSAT`, or `SAT`
followed by a line with one literal per variable `1..V` and a closing `0`.
Exit status is 0 in both cases.

```
$ printf 'p cnf 3 2\n1 -2 0\n2 3 0\n' | ./run.sh
SAT
-1 -2 3 0
```

Without installing: `PYTHONPATH=src python3 -m cdcl_sat < file.cnf`.
After `pip install`, the `cdcl-sat` command does the same.

## Library

```python
from cdcl_sat import Solver, parse_dimacs, format_result, solve

# One-shot: literals are DIMACS integers (k = variable k true, -k = false).
model = solve(3, [[1, -2], [2, 3]])      # [bool, bool, bool] or None if UNSAT
# model[i] is the value of variable i + 1

# Incremental construction:
s = Solver(2)
s.add_clause([1, 2])
s.add_clause([-1])        # returns False once the formula is trivially UNSAT
print(s.solve())          # [False, True]

# DIMACS text in, DIMACS-style result out:
cnf = parse_dimacs("p cnf 2 2\n1 2 0\n-1 0\n")
print(format_result(cnf.num_vars, solve(cnf.num_vars, cnf.clauses)), end="")
```

A `Solver` is single-shot: call `solve()` once after adding all clauses.

## Tests

```
python3 -m pytest
```
