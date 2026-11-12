# typeinfer

Hindley-Milner type inference for a small ML-like language, as a Rust library
and a command-line tool. It reads a program (a sequence of `;;`-terminated
declarations) and prints the principal type of each declaration, or an error
(`unify`, `occurs`, `unbound`) for declarations that do not type-check.

The language has integers, booleans, `unit`, functions, tuples, lists, `let` and
`let rec` with full let-polymorphism (no value restriction), and built-ins
`not fst snd hd tl null length map fold`. Dependencies: the standard library
only.

## Build

```sh
cargo build --release     # or ./build.sh
cargo test                # unit, integration and doc tests
```

The binary is `target/release/typeinfer`; `./run.sh` runs it from any directory.

## Command line

The program is read from standard input; one line per declaration is written to
standard output. The exit status is 0 whenever the input was processed (a type
error is a normal result); it is 2 if the input cannot be read as UTF-8 or is
syntactically malformed.

```console
$ ./run.sh <<'END'
let compose f g x = f (g x);;
let rec len l = if null l then 0 else 1 + len (tl l);;
(len [true], len [1; 2]);;
fun f -> (f 1, f true);;
fun x -> x x;;
nope;;
END
compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b
len : 'a list -> int
- : int * int
error: unify
error: occurs
error: unbound
```

Output lines are `name : type` for `let`/`let rec`, `- : type` for a bare
expression, and `error: <kind>` for a failure. A failed declaration binds
nothing. Type variables are renamed `'a`, `'b`, ... per declaration.

## Library

```rust
use typeinfer::{Session, TypeError};

fn main() {
    // One-shot: render a whole program the way the CLI does.
    let out = typeinfer::infer_to_string("let id = fun x -> x;; (id 1, id true);;").unwrap();
    assert_eq!(out, "id : 'a -> 'a\n- : int * bool\n");

    // Incremental: a Session keeps the top-level environment between calls
    // and exposes structured results.
    let mut session = Session::new();
    let results = session.infer_source("let xs = [1; 2];; hd xs;; hd 1;; y;;").unwrap();
    assert_eq!(results[0].to_string(), "xs : int list");
    assert_eq!(results[1].outcome, Ok("int".to_string()));
    assert_eq!(results[2].outcome, Err(TypeError::Unify));
    assert_eq!(results[3].outcome, Err(TypeError::Unbound));
}
```

Modules: `lexer`, `parser` and `ast` (syntax), `types` (type graph,
unification, generalisation, instantiation), plus `Session` for the top-level
driver. See the crate docs (`cargo doc --open`).

## How it works

Algorithm J: one left-to-right pass that unifies as it goes, so when a
declaration has several problems the first one met is reported.

* Types are a shared DAG in an arena. Variables are union-find nodes with a
  level; constructor nodes are linked after a successful unification so
  repeated unification of shared sub-terms is cheap.
* Generalisation is level-based (Rémy): a `let` right-hand side is inferred one
  level deeper and its variables above the outer level are quantified, without
  scanning the environment.
* Occurs check, generalisation, instantiation and printing each visit every
  distinct node once, so large shared types are never expanded. Instantiation
  shares sub-terms that contain no quantified variable.
* The environment keeps a stack of bindings per identifier, so lookup does not
  depend on how many names are in scope. Monomorphic bindings are used as is.
* Parsing and inference recurse on expression depth, so the source-level API
  runs on a helper thread with a 1 GiB (virtual) stack.
