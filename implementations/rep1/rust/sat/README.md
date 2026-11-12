# cdcl-sat

A small, dependency-free CDCL SAT solver for formulas in DIMACS CNF format,
written in Rust (standard library only). It is a MiniSat-style solver:

- two watched literals (with blocking literals) for unit propagation;
- first-UIP conflict analysis with local (non-recursive) clause minimisation;
- VSIDS branching (double-precision activities, decay 0.95, heap-ordered) and
  phase saving (initial phase: false);
- Luby restarts (`100 * luby(2, i)` conflicts);
- periodic deletion of the lower-activity half of the learnt clauses (binary
  clauses are kept), triggered after a restart once `max_learnts` is reached;
- root-level simplification of input clauses (duplicates, tautologies,
  satisfied clauses, false literals, unit propagation).

## Build

```sh
./build.sh            # or: cargo build --release
```

The binary is `target/release/sat`; `./run.sh` runs it from any directory.

## Command-line usage

The program reads a DIMACS CNF file on standard input and writes the result to
standard output (exit status 0 for both answers):

```sh
$ printf 'p cnf 3 2\n1 -2 0\n2 3 0\n' | ./run.sh
SAT
-1 -2 3 0
$ printf 'p cnf 1 2\n1 0\n-1 0\n' | ./run.sh
UNSAT
```

For a satisfiable formula the first line is `SAT` and the second lists one
literal per variable `1..V` in order, ending with `0`. For an unsatisfiable
one the output is just `UNSAT`. Malformed input prints a message on stderr and
exits with status 2.

## Library usage

```rust
use cdcl_sat::{Lit, Solver};

// Directly, with the incremental-style API:
let mut solver = Solver::new();
solver.reserve_vars(3);
solver.add_clause(&[Lit::from_dimacs(1), Lit::from_dimacs(-2)]);
solver.add_clause(&[Lit::from_dimacs(2), Lit::from_dimacs(3)]);
if solver.solve() {
    println!("{:?}", solver.model()); // entry i is DIMACS variable i + 1
}

// Or from DIMACS text:
let answer = cdcl_sat::solve_dimacs("p cnf 2 2\n1 2 0\n-1 0\n").unwrap();
assert_eq!(answer, "SAT\n-1 2 0\n");
```

Modules:

| module | contents |
| --- | --- |
| `lit` | `Var`, `Lit` and their DIMACS conversions |
| `dimacs` | `parse`, `Cnf`, `ParseError`, `format_answer` |
| `solver` | `Solver`, `Stats` |

Top-level helpers: `solver_from_cnf`, `solve_cnf`, `solve_dimacs`.

## Tests

```sh
cargo test --release
```

Unit tests live next to the code; `tests/solver.rs` checks the solver against
brute force on random formulas and on pigeonhole / random 3-SAT instances, and
`tests/cli.rs` runs the binary end to end.
