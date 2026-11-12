# sat

A CDCL SAT solver for formulas in [DIMACS CNF](https://people.sc.fsu.edu/~jburkardt/data/cnf/cnf.html),
written in D using only the standard library. It is a reusable library
(`sat`) with a thin command-line tool on top.

The solver is MiniSat-style:

- two watched literals per clause (with blocking literals) for unit propagation;
- first-UIP conflict analysis with local (non-recursive) clause minimisation;
- VSIDS branching (double-precision activities, decay 0.95, rescaling at 1e100)
  using a binary heap, with phase saving (initial phase: false);
- Luby restarts (unit 100 conflicts);
- learnt-clause deletion after restarts once `max_learnts` is reached
  (`max(stored clauses / 3, 2000)`, growing by 1.1×): the lower-activity half is
  dropped, binary and reason clauses are kept.

Input clauses are simplified at the root (duplicates, tautologies, satisfied
clauses, false literals, units).

## Build

Requires LDC and dub.

```sh
./build.sh          # = dub build -b release --compiler=ldc2
```

This produces `bin/sat`.

## Command line

`run.sh` (or `bin/sat`) reads a DIMACS CNF file on standard input and writes the
answer to standard output:

```sh
$ printf 'p cnf 3 2\n1 -2 0\n2 3 0\n' | ./run.sh
SAT
-1 -2 3 0
$ printf 'p cnf 1 2\n1 0\n-1 0\n' | ./run.sh
UNSAT
```

On `SAT`, the second line gives every variable `1..V` as a signed literal,
followed by `0`. The exit status is 0 for both answers (2 for unparsable input).
Comments, blank lines, clauses spanning lines, empty clauses and tautologies
are all handled as described in the DIMACS format.

## Library

Add it as a dub dependency (configuration `library`) and `import sat;`:

```d
import sat;

void main()
{
    // From DIMACS text:
    auto cnf = parseDimacs("p cnf 3 2\n1 -2 0\n2 3 0\n");
    auto res = solveCnf(cnf);
    assert(res.satisfiable && satisfies(cnf, res.model));

    // Or build a formula directly with the Solver class:
    auto s = new Solver;
    s.addClause([1, 2]);      // x1 or x2
    s.addClause([-1]);        // not x1
    if (s.solve() == SolveStatus.sat)
        assert(!s.model[0] && s.model[1]);   // model[i] is variable i+1
}
```

Modules:

| module        | contents                                                        |
|---------------|-----------------------------------------------------------------|
| `sat.dimacs`  | `Cnf`, `parseDimacs`, `solveCnf`, `SolveResult`, `formatResult` |
| `sat.solver`  | `Solver` (`addClause`, `solve`, `model`, `stats`), `luby`       |
| `sat.model`   | `satisfies`: check an assignment against a `Cnf`                |
| `sat.types`   | `Lit`, `LBool`                                                  |
| `sat.order`   | `VarOrder`: VSIDS activities and the decision heap              |
| `sat.clause`  | `Clause`: internal clause storage                               |

## Tests

```sh
dub test --compiler=ldc2    # unittest blocks: parser, heap, Luby, solver vs.
                            # brute force, pigeonhole, random 3-SAT, ...
./build.sh && tests/cli.sh  # command-line smoke tests
```

## License

MIT
