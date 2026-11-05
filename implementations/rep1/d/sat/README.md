# sat

A conflict-driven clause-learning (CDCL) SAT solver in D, as a reusable library
plus a small DIMACS command-line tool. Standard library only.

The solver is MiniSat-style: two watched literals, first-UIP learning with
local clause minimisation, VSIDS branching over an indexed binary heap, phase
saving, Luby restarts (`100 * luby(2, i)` conflicts) and periodic deletion of
the less active half of the learnt clauses. The search is fully deterministic.

## Layout

```
src/sat/        the library (import sat;)
  types.d       literal encoding helpers
  luby.d        Luby restart sequence
  heap.d        indexed max-heap of variables (VSIDS order)
  dimacs.d      DIMACS parser (Cnf, parseDimacs) and output formatter
  solver.d      Solver, Result
cli/main.d      the command-line tool
tests/          unit tests (separate from the library sources)
build.sh        builds the CLI; run.sh runs it
```

## Build

Requires LDC and dub.

```
./build.sh          # dub build -b release --compiler=ldc2 --config=cli  ->  ./sat
dub test --compiler=ldc2
```

## Command line

`sat` reads a DIMACS CNF file on standard input and writes the answer to
standard output (exit status 0 in both cases). It takes no arguments.

```
$ printf 'p cnf 3 2\n1 -2 0\n2 3 0\n' | ./run.sh
SAT
-1 -2 3 0
$ printf 'p cnf 2 4\n1 2 0\n-1 2 0\n-1 -2 0\n1 -2 0\n' | ./run.sh
UNSAT
```

On `SAT` the second line lists one literal per variable `1..V` followed by `0`.
Comments, blank lines, clauses spanning lines, empty clauses, repeated literals
and tautologies are all accepted as described in the DIMACS format.

## Library

```d
import std.stdio;
import sat;

void main()
{
    // Programmatic use: variables are 1..n, literals are DIMACS integers.
    auto s = new Solver(3);
    s.addClause([1, -2]);
    s.addClause([2, 3]);
    s.addClause([-1, -3]);
    if (s.solve() == Result.sat)
    {
        foreach (v; 0 .. s.numVars)             // modelValue takes 0-based variables
            writeln("x", v + 1, " = ", s.modelValue(v));
    }

    // From DIMACS text:
    auto cnf = parseDimacs(cast(const(ubyte)[]) "p cnf 1 2\n1 0\n-1 0\n");
    auto s2 = Solver.fromCnf(cnf);
    assert(s2.solve() == Result.unsat);
}
```

Public API (all re-exported by `import sat;`):

- `Solver(numVars)`, `addClause(int[])` (returns `false` once the formula is
  known unsatisfiable), `solve()` -> `Result.sat | Result.unsat`,
  `modelValue(v)`, `Solver.fromCnf(cnf)`.
- `parseDimacs(ubyte[] | char[])` -> `Cnf { numVars, literals, ends }`.
- `formatResult(result, numVars, isTrue)` -> the exact bytes the CLI prints.
- `VarHeap`, `luby`, and the literal helpers in `sat.types`.
