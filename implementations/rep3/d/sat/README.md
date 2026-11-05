# sat

A conflict-driven clause-learning (CDCL) SAT solver for DIMACS CNF, written in
D using only the standard library. It is split into a reusable library
(`source/sat/`) and a thin command-line tool (`app/main.d`).

The solver is MiniSat-style: two watched literals, first-UIP clause learning
with local minimisation, VSIDS branching on an indexed binary heap with phase
saving, Luby restarts (100 conflicts × Luby sequence) and activity-based
reduction of the learnt-clause database between restarts. All tie-breaking is
deterministic, so a given formula always produces the same search and the same
model.

## Build

Requires LDC (tested with 1.41.0) and dub (1.40.0).

```sh
./build.sh          # same as: dub build -b release --compiler=ldc2
```

This produces `bin/sat`. `./run.sh` runs it from any directory.

## Command-line use

`sat` takes no arguments. It reads a DIMACS CNF formula on standard input and
writes the verdict on standard output; the exit status is 0 in both cases.

```sh
$ printf 'c example\np cnf 3 2\n1 -2 0\n2 3 0\n' | ./run.sh
SAT
-1 -2 3 0
$ printf 'p cnf 1 2\n1 0\n-1 0\n' | ./run.sh
UNSAT
```

* Satisfiable: `SAT`, then one line with a literal for **every** variable
  `1..V` in increasing order, ending in `0` (`0` alone when `V = 0`).
* Unsatisfiable: `UNSAT`.

Input handling: comment lines (`c ...`) and blank lines are allowed anywhere,
clauses may span lines or share a line, and empty clauses, repeated literals
and tautologies (`1 -1 0`, treated as satisfied) are accepted.

## Library use

Add the project as a dub dependency (it provides a `library` configuration) or
compile `source/` with your program, then `import sat;`.

```d
import std.stdio;
import sat;

void main()
{
    // High-level: parse DIMACS text, solve, print in the CLI format.
    auto cnf = parseDimacs("p cnf 3 2\n1 -2 0\n2 3 0\n");
    auto result = solve(cnf);
    write(cast(string) renderResult(result.satisfiable, result.model));

    // Lower level: build the solver clause by clause (DIMACS literals).
    auto solver = new Solver(3);
    solver.addClause([1, -2]);
    solver.addClause([-1, 3]);
    solver.addClause([2, 3]);
    if (solver.solve())
        writeln(solver.model);          // value of variables 1..3
    writeln(solver.stats.conflicts);    // search statistics
}
```

### Modules

| module        | contents                                                          |
|---------------|-------------------------------------------------------------------|
| `sat.solver`  | `Solver` (CDCL engine), `solve(Cnf)`, `SolveResult`, `Stats`      |
| `sat.dimacs`  | `Cnf` and `parseDimacs` (byte-buffer DIMACS parser)               |
| `sat.output`  | `renderResult`: the `SAT`/`UNSAT` text of the CLI                 |
| `sat.heap`    | `VarHeap`, an indexed max-heap keyed by activity                  |
| `sat.luby`    | `luby2`, the Luby restart sequence                                |
| `sat.types`   | literal encoding (`Lit = 2*var + sign`) and helpers               |

`import sat;` re-exports all of them.

## Tests

```sh
dub test --compiler=ldc2
```

The unit tests live under `tests/sat/`, separate from the library sources, and
include randomised comparison against brute force and pigeonhole formulas.

## Layout

```
dub.sdl            manifest (configurations: cli, library, unittest)
build.sh run.sh    build and run scripts
source/sat/        library
app/main.d         command-line tool
tests/sat/         unit tests
```
