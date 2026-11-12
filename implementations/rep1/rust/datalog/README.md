# datalog

A Datalog engine with stratified negation, written in Rust with no
dependencies. It reads a program (facts, rules, queries), rejects it if it is
unsafe or not stratifiable, computes the perfect model bottom-up with
**semi-naive evaluation**, and answers the queries.

* Constants are integers or lower-case identifiers (integers sort first).
* Rule bodies may contain positive atoms, `not` atoms and the comparisons
  `< <= > >= = !=`.
* Evaluation: predicate dependency graph → strongly connected components
  (Tarjan) → strata evaluated in dependency order. Each rule is compiled once
  into an indexed nested-loop join (delta atom first, then the atom with the
  most bound arguments); hash indexes are built per access pattern and
  maintained incrementally, never rebuilt. Non-linear rules get one delta
  variant per recursive atom.

## Build

```
./build.sh          # or: cargo build --release
```

The binary is `target/release/datalog`.

## Command line

The program is read from stdin; answers go to stdout; the exit code is 0.

```
$ cat > prog.dl <<'EOT'
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(1, X).
?- path(4, X).
EOT
$ ./run.sh < prog.dl
path(1, 1)
path(1, 2)
path(1, 3)
path(1, 4)
-- 4
-- 0
```

For each query, in input order, the matching tuples are printed in ascending
order (integers before identifiers, identifiers bytewise), then `-- N` with
the count. If the program is unsafe (a head, negated or comparison variable
not bound by a positive body atom), not stratifiable (a negative edge on a
dependency cycle), or malformed, the only output is `error` (details go to
stderr).

## Library

```rust
use datalog::{evaluate, Constant, Program};

fn main() {
    let program = Program::parse(
        "parent(ann, bob). parent(bob, cy).
         anc(X, Y) :- parent(X, Y).
         anc(X, Z) :- parent(X, Y), anc(Y, Z).
         ?- anc(ann, X).",
    )
    .unwrap();

    let model = evaluate(&program).unwrap(); // safety + stratification checked here
    let rows = model.query(&program.queries[0]);
    assert_eq!(rows, vec![
        vec![Constant::from("ann"), Constant::from("bob")],
        vec![Constant::from("ann"), Constant::from("cy")],
    ]);

    // Or text in, text out, exactly like the CLI:
    let _text: String = datalog::run("p(1). ?- p(X).").unwrap();
}
```

Modules: `parser`/`ast` (syntax), `analysis` (safety, stratification),
`relation` (indexed tuple sets), `eval` (semi-naive evaluator and `Model`),
`constant`, `error`. See `cargo doc --open`.

## Tests

```
cargo test
```

Unit tests live next to the code; `tests/spec_examples.rs` holds end-to-end
tests through the public API.
