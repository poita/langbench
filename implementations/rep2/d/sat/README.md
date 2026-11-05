# sat

A conflict-driven clause-learning (CDCL) SAT solver in D, packaged as a
reusable library plus a thin DIMACS command-line tool. Standard library only.

The solver is MiniSat-style: two watched literals, first-UIP clause learning
with local minimisation, VSIDS branching on an indexed heap, phase saving, Luby
restarts, and periodic learnt-clause reduction. The search is deterministic.

## Layout

| Path | Contents |
| --- | --- |
| `source/sat/types.d` | literal encoding helpers (`2v` / `2v+1`, DIMACS conversion) |
| `source/sat/heap.d` | `VarHeap`, the indexed max-heap behind VSIDS |
| `source/sat/solver.d` | `Solver`, `SolveResult`, `luby` |
| `source/sat/dimacs.d` | DIMACS parsing (`parseDimacs`), `solveCnf`, `formatResult`, `satisfies` |
| `source/sat/package.d` | `import sat;` re-exports everything |
| `app/main.d` | the command-line tool |
| `tests/` | unit tests (kept apart from the library sources) |

## Build

Requires LDC and dub.

```sh
dub build -b release --compiler=ldc2     # produces bin/sat-cli
./build.sh                               # same, from any directory
dub test --compiler=ldc2                 # unit tests
```

## Command line

`bin/sat-cli` (or `./run.sh`) reads a DIMACS CNF file on standard input and
writes the answer to standard output; it takes no arguments and exits 0.

```
$ printf 'p cnf 3 2\n1 -2 0\n2 3 0\n' | ./run.sh
SAT
-1 -2 3 0
$ printf 'p cnf 1 2\n1 0\n-1 0\n' | ./run.sh
UNSAT
```

For a satisfiable formula the output is `SAT` followed by one line with a
literal for every variable `1..V` (negative = false) and a final `0`.
Comments, blank lines, and clauses spanning lines or sharing a line are
accepted; empty clauses make the formula unsatisfiable and tautologies are
treated as satisfied.

## Library

Add the package to your `dub.sdl` (`dependency "sat" path="..."`, with
`subConfiguration "sat" "library"`), then:

```d
import std.stdio;
import sat;

void main()
{
    // Build a formula directly with the solver ...
    auto s = new Solver(3);          // variables 1..3
    s.addClause([1, -2]);            // x1 or not x2
    s.addClause([2, 3]);             // x2 or x3
    s.addClause([-3]);               // not x3
    if (s.solve() == SolveResult.sat)
        foreach (v; 1 .. 4)
            writeln("x", v, " = ", s.modelValue(v));

    // ... or parse DIMACS text and solve it.
    auto cnf = parseDimacs("p cnf 2 2\n1 2 0\n-1 0\n");
    bool[] model;
    if (solveCnf(cnf, model) == SolveResult.sat)
        assert(satisfies(cnf, model));
}
```

`addClause` takes DIMACS literals and returns `false` once the formula is known
to be unsatisfiable. A `Solver` is single-shot: add all clauses, then call
`solve()` once.
