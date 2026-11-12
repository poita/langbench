# cdcl-sat

A small, dependency-free CDCL SAT solver in pure Python (standard library
only). It reads formulas in DIMACS CNF and either prints a satisfying
assignment or `UNSAT`.

The design follows MiniSat: two watched literals, first-UIP clause learning
with local minimisation, VSIDS branching over an indexed heap with phase
saving, Luby restarts (unit 100) and activity-based learnt-clause deletion.

## Layout

```
src/cdcl_sat/
    dimacs.py   DIMACS parser and result formatter
    solver.py   Solver class (propagation, analysis, search, reduction) and solve()
    heap.py     indexed max-heap used for VSIDS decisions
    luby.py     Luby restart sequence
    cli.py      command-line front end
tests/          pytest suite
build.sh        byte-compiles the sources
run.sh          runs the CLI (no install needed)
```

## Build

```
./build.sh
```

There is nothing to install; `build.sh` just byte-compiles `src/`. To install
the package anyway (`pip install .` gives a `cdcl-sat` command) use the
`pyproject.toml` manifest. Requires Python 3.10+ (developed on 3.14).

## Command line

```
./run.sh < problem.cnf
```

Standard input is DIMACS CNF; standard output is exactly one of

```
UNSAT
```

or

```
SAT
1 -2 3 0
```

where the second line has one literal per variable `1..V` followed by `0`.
The exit status is 0 in both cases. Equivalent: `PYTHONPATH=src python3 -m cdcl_sat`.

## Library

```python
from cdcl_sat import Solver, solve, parse_dimacs

# One-shot: DIMACS-style integer clauses
model = solve([[1, -2], [2, 3], [-1, -3]])   # e.g. [-1, -2, 3], or None if UNSAT

# Incremental use
s = Solver()
s.add_clause([1, 2])
s.add_clause([-1, 2])
if s.solve():
    print(s.model())          # [-1, 2]  (one signed literal per variable)
s.add_clause([-2])
print(s.solve())              # False

# From DIMACS text
cnf = parse_dimacs("p cnf 2 2\n1 2 0\n-1 0\n")
print(solve(cnf.clauses, cnf.num_vars))
```

`Solver.add_clause` simplifies at the root (duplicates, tautologies and
satisfied clauses are dropped, false literals removed, units propagated) and
returns `False` once the formula is trivially unsatisfiable. `Solver.solve`
returns `True`/`False`; after `True`, `model()` gives the assignment.
Statistics are available as `conflicts`, `decisions`, `propagations` and
`restarts`.

## Tests

```
python3 -m pytest
```
