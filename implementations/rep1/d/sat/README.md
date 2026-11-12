# sat

A CDCL SAT solver for formulas in DIMACS CNF, written in D with only the
standard library. It is a reusable library (`sat`) plus a thin command-line
tool.

Algorithm (MiniSat style): two-watched-literal unit propagation, first-UIP
conflict analysis with local clause minimisation, VSIDS branching (decay 0.95)
with phase saving, Luby restarts (`100 * luby(2, i)` conflicts), and periodic
deletion of the less active half of the learnt clauses (binary ones are kept).
Input clauses are simplified at the root (duplicates, tautologies, satisfied
clauses, false literals, units).

## Build

Requires LDC and dub (developed with LDC 1.41.0, dub 1.40.0).

```sh
./build.sh            # = dub build -b release --compiler=ldc2; produces bin/sat
dub test --compiler=ldc2   # run the unit tests
```

## Command line

`bin/sat` (or `./run.sh`) reads a DIMACS CNF formula on standard input and
writes one of the following to standard output, exiting with status 0:

```
SAT
1 -2 3 0        # one literal per variable 1..V, then 0
```
```
UNSAT
```

```sh
printf 'p cnf 3 2\n1 -2 0\n2 3 0\n' | ./run.sh
```

Malformed input is reported on standard error with exit status 2.

## Library

Modules (all re-exported by `import sat;`):

| module        | contents                                                      |
|---------------|---------------------------------------------------------------|
| `sat.dimacs`  | `Cnf`, `parseDimacs`, `formatAnswer`, `satisfies`             |
| `sat.solver`  | `Solver` (incremental clause adding + `solve`), `solve(Cnf)`  |
| `sat.order`   | `VarOrder`: VSIDS activities and the decision heap            |
| `sat.luby`    | `luby`: the restart sequence                                  |
| `sat.types`   | literal encoding helpers                                      |
| `sat.vec`     | `Vec!T`: growable array that keeps capacity on truncation     |

Use it from another dub project with `dependency "sat" path="../sat"` and the
`library` configuration (`subConfiguration "sat" "library"`).

```d
import std.stdio;
import sat;

void main()
{
    // One call, from DIMACS text:
    auto cnf = parseDimacs("p cnf 3 2\n1 -2 0\n2 3 0\n");
    auto result = solve(cnf);
    writeln(result.satisfiable, " ", result.model);   // true [...]
    assert(satisfies(cnf, result.model));

    // Or drive the solver directly (literals are DIMACS integers):
    auto s = new Solver;
    s.addClause([1, 2]);
    s.addClause([-1, 2]);
    s.addClause([-2, 3]);
    if (s.solve())
        writeln(s.model);                             // [x, true, true]
    writeln(formatAnswer(s.okay, s.model));
}
```

## Tests

Unit tests are D `unittest` blocks next to the code (D's built-in test
framework, so there are no extra dependencies): parser edge cases, the Luby
sequence, the heap, and the solver against brute force on random small
formulas, random 3-SAT near the threshold, and pigeonhole formulas.

## Layout

```
dub.sdl         package manifest (configurations: cli, library)
source/sat/     the library
app/main.d      the command-line tool
build.sh run.sh build and run scripts
```
