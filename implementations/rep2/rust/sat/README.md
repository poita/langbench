# cdcl-sat

A small, dependency-free CDCL SAT solver written in Rust (standard library
only), with a DIMACS CNF reader and a command-line tool.

The solver follows the MiniSat design:

- two watched literals per clause for unit propagation;
- first-UIP conflict analysis with local (non-recursive) clause minimisation;
- VSIDS branching (double-precision activities, decay 0.95 / 0.999, rescaling)
  on an indexed binary heap, with phase saving (initial phase: false);
- Luby restarts (`100 * luby(2, i)` conflicts);
- learnt-clause deletion after a restart once `max_learnts` is reached
  (initially `max(stored clauses / 3, 2000)`, ×1.1 per reduction): the
  lower-activity half is deleted, binary clauses are kept;
- root simplification of input clauses (duplicates, tautologies, satisfied
  clauses, false literals, units).

## Build

```sh
./build.sh            # or: cargo build --release
```

The binary is `target/release/sat`.

## Command line

`sat` reads a DIMACS CNF formula on standard input and writes the answer to
standard output; it takes no arguments (`./run.sh` just launches the binary).

```sh
$ printf 'p cnf 3 2\n1 -2 0\n2 3 0\n' | ./run.sh
SAT
-1 -2 3 0
$ printf 'p cnf 1 2\n1 0\n-1 0\n' | ./run.sh
UNSAT
```

Output is `UNSAT`, or `SAT` followed by one line with a literal for every
variable `1..V` in order and a terminating `0`. The exit status is 0 for both
answers (2 if the input cannot be read or parsed).

## Library

```rust
use cdcl_sat::{Cnf, Lit, SolveResult, Solver};

// From DIMACS text:
let cnf = Cnf::parse("p cnf 2 3\n1 2 0\n-1 2 0\n-2 1 0\n").unwrap();
match cnf.solve() {
    SolveResult::Sat(model) => assert_eq!(model, vec![true, true]),
    SolveResult::Unsat => unreachable!(),
}

// Or incrementally through the solver API:
let mut s = Solver::new(2);
s.add_clause(&[Lit::from_dimacs(1), Lit::from_dimacs(2)]);
s.add_clause(&[Lit::from_dimacs(-1)]);
assert_eq!(s.solve(), SolveResult::Sat(vec![false, true]));
```

Modules: `lit` (variables/literals), `heap` (activity-ordered priority queue),
`solver` (the CDCL engine), `dimacs` (parsing and result formatting). Run
`cargo doc --open` for the full API.

## Tests

```sh
cargo test
```

Unit tests live next to the code, `tests/solver.rs` cross-checks the solver
against brute force and structured UNSAT families (pigeonhole), and
`tests/cli.rs` drives the compiled binary.
