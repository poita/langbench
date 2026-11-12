# langvm

A compiler and stack virtual machine for **Vellum**, a small statically typed
language with modules, structs, sum types with exhaustive pattern matching,
generics with local type inference, traits and impls, closures, 64-bit wrapping
integers, IEEE-754 doubles, lists, insertion-ordered maps and a 132-function
standard library.

`langvm` reads a multi-module Vellum program on standard input, type-checks and
compiles it to bytecode, runs it on a stack VM, and writes the program's output
to standard output. It is written in Rust using only the standard library.

- A program that does not compile prints exactly one diagnostic line,
  `error: <kind> at <line>:<col>`, and nothing else.
- A program that compiles but fails at run time prints its output followed by
  one `panic: <message>` line.
- The exit code is always `0`.

## Building

Requires Rust 1.96 (or newer) and Cargo.

```sh
./build.sh                  # or: cargo build --release
```

The binary is `target/release/langvm`. `./run.sh` runs it from any directory.

## Command-line usage

The tool takes no arguments. The whole of stdin is one *module stream*: a
sequence of modules, each introduced by a line `@module <name>`.

```sh
$ cat hello.vel
@module main
use util;

fn main() {
    print(util::greet("world"));
}
@module util
pub fn greet(who: Str) -> Str {
    "hello, " ++ who
}

$ ./run.sh < hello.vel
hello, world
```

Compile errors, panics and normal runs all exit with status 0:

```text
$ printf '@module main\nfn main() { let n: Int = "x"; }\n' | ./run.sh
error: type-mismatch at 1:26
$ printf '@module main\nfn main() { print("a"); panic("boom"); }\n' | ./run.sh
a
panic: boom
```

## Using the library

The crate `langvm` exposes each stage of the pipeline.

```rust
// One call: compile and run, returning everything written to stdout.
let src = "@module main\nfn main() { print(showInt(6 * 7)); }\n";
assert_eq!(langvm::run_source(src), "42\n");

// Rejected programs yield the diagnostic line.
let bad = "@module main\nfn main() { let x: Int = true; }\n";
assert_eq!(langvm::run_source(bad), "error: type-mismatch at 1:26\n");

// Or drive the stages yourself.
match langvm::compile(src) {
    Ok(program) => {
        let stdout: Vec<u8> = langvm::run(&program);
        assert_eq!(stdout, b"42\n");
    }
    Err(diag) => eprintln!("{}", diag), // "error: <kind> at <line>:<col>"
}
```

`run_source` executes on a thread with a large stack so that very deep data
structures cannot overflow the host stack; `compile` and `run` run on the
calling thread.

### Crate layout

| Module | Responsibility |
|---|---|
| `source` | splitting stdin into modules (`bad-module`, `dup-module`) |
| `lexer`, `parser`, `ast` | tokens and the recursive-descent parser |
| `program`, `resolve` | namespaces, `use`, visibility, type resolution, impl registry (pass 3) |
| `types`, `infer` | semantic types and unification with the occurs check |
| `check` | bidirectional type checker producing the resolved IR (`ir`) |
| `exhaust` | pattern usefulness, exhaustiveness and reachability |
| `compile`, `bytecode` | IR to stack-machine code |
| `vm`, `value`, `stdlib`, `builtins`, `numfmt` | the interpreter, run-time values and the standard library |
| `diag` | positions and the 51 diagnostic kinds |

The VM keeps its own call-frame stack, so the Vellum call depth (limit 20000
frames) is independent of the host stack. Method dispatch is an O(1) table
lookup by trait and head constructor; strings are arrays of Unicode scalar
values, so `charAt` and `strLen` are O(1); maps are insertion-ordered hash
maps.

## Testing

```sh
cargo test --release
```

- unit tests inside the lexer, parser, number formatting and built-in table;
- `tests/examples.rs` runs every worked example of the language specification
  (inputs and expected outputs in `tests/examples/`);
- `tests/diagnostics.rs` covers diagnostic kinds, positions and pass order;
- `tests/runtime.rs` covers panics, integer/float semantics, strings,
  collections, closures, traits and the call-depth limit;
- `tests/cli.rs` runs the compiled binary end to end.
