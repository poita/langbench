# datalog

A small, dependency-free Datalog engine with stratified negation, written in
Rust. It is a library (`datalog`) plus a thin command-line tool of the same
name that reads a program on stdin and prints the answers to its queries.

* **Language**: facts, rules, queries, negated atoms (`not p(X)`), comparisons
  (`<`, `<=`, `>`, `>=`, `=`, `!=`), integer and symbolic constants, `_`.
* **Checks**: rule safety, and stratifiability (Tarjan SCC on the predicate
  dependency graph; no negative edge inside a cycle).
* **Evaluation**: bottom-up *semi-naive* evaluation per strongly connected
  component, compiled join plans (delta atom first, then most-bound-first),
  hash indexes maintained incrementally, constants interned to their rank in
  the total order so every comparison is an integer comparison.

## Build

```sh
./build.sh            # = cargo build --release
```

Requires Rust 1.80+ (developed with 1.96). No external crates.

## Command line

```sh
./run.sh < program.dl
```

The program is the whole of stdin. For each `?- atom.` query, in order, the
matching tuples are printed in ascending order, one per line as
`pred(v1, v2, …)`, followed by `-- N`, the number of tuples. If the program has
an unsafe rule or is not stratifiable, the only output is `error`. Exit status
is 0 in both cases (2 for malformed input or I/O failure; the message goes to
stderr).

```console
$ cat > tc.dl <<'EOF2'
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(1, X).
EOF2
$ ./run.sh < tc.dl
path(1, 1)
path(1, 2)
path(1, 3)
path(1, 4)
-- 4
```

Constants are ordered with every integer before every identifier, integers
numerically, identifiers bytewise (`a` < `a0` < `aa` < `b`); this order is used
by the comparison operators and for sorting output.

## Library

```rust
use datalog::{parse, Const, Model};

let program = parse("
    edge(1, 2). edge(2, 3).
    path(X, Y) :- edge(X, Y).
    path(X, Z) :- path(X, Y), edge(Y, Z).
    ?- path(1, X).
").unwrap();

// Checks safety and stratification, then computes the perfect model.
let model = Model::compute(&program).unwrap();

for query in &program.queries {
    for tuple in model.query(query) {
        println!("{:?}", tuple);
    }
}
assert_eq!(model.count("path", 2), 3);

// Or do everything at once and get the CLI's text output:
assert!(datalog::run("p(1). ?- p(X).").unwrap().starts_with("p(1)"));
```

Modules:

| module     | responsibility                                                   |
|------------|------------------------------------------------------------------|
| `ast`      | `Program`, `Rule`, `Atom`, `Literal`, `Term`, `Const`            |
| `lexer`, `parser` | text → `Program` (`parse`)                                |
| `analysis` | `check_safety`, `stratify` (SCCs in evaluation order)            |
| `symbols`  | predicate table and constant interning                           |
| `relation` | tuple sets with incrementally maintained hash indexes            |
| `eval`     | semi-naive evaluation → `Model`, queries                         |
| `error`    | `Error`, `ParseError`                                            |

Join planning and execution are internal modules (`plan`, `join`).

## Tests

```sh
cargo test
```

Unit tests live beside the code; `tests/spec_examples.rs` covers the language
semantics end to end, and `tests/differential.rs` compares the engine against a
naive evaluator on random stratified programs.
