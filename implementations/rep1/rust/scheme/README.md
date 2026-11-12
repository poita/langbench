# scheme

An interpreter for a small Scheme subset, written in Rust using only the
standard library. It provides:

* arbitrary-precision integers (a from-scratch bignum: schoolbook
  multiplication, Knuth's Algorithm D division, decimal output by repeated
  division by 10^9);
* proper tail calls (a trampolined evaluator), and non-tail recursion at least
  10,000 deep;
* a pre-analysing design: each form is converted once into a tree of nodes, and
  variables are looked up by name through a chain of frames at run time.

The language is specified in `problems/scheme/SPEC.md`: `quote`, `if`,
`define`, `set!`, `lambda`, `let`, named `let`, `let*`, `letrec`, `begin`,
`cond`, `and`, `or`, plus a fixed set of primitives (integer arithmetic and
comparison, pairs and lists, predicates, `eq?`/`equal?`, `apply`, `error`,
basic strings and symbols, `display`, `newline`).

## Building

```sh
./build.sh            # or: cargo build --release
```

The binary is `target/release/scheme`. `run.sh` runs it from any directory.

## Command-line use

The program is read from standard input; output goes to standard output.

```sh
echo '(define (sq x) (* x x)) (sq 12) (display "hi") (newline)' | ./run.sh
# 144
# hi
```

* The printed value of each top-level form that is not void is written on its
  own line; `display` and `newline` output is interleaved in program order.
* On a runtime error, `error: <category>` and a newline are appended directly to
  the output and evaluation stops. Categories: `unbound-variable`,
  `type-error`, `arity-error`, `division-by-zero`, `user-error`.
* The exit code is 0 even after a Scheme error. The CLI runs the interpreter on
  a thread with a 1 GiB (lazily committed) stack so deep non-tail recursion works.

## Library use

```rust
use scheme::{run_to_string, Interpreter};

// One-shot: run a program, get its output.
assert_eq!(run_to_string("(display (* 99999999999 99999999999))"),
           "9999999999800000000001");

// Or drive an interpreter yourself, with any `std::io::Write` as output.
let mut out = Vec::new();
let mut interp = Interpreter::new(&mut out);
interp.run("(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))").unwrap();
interp.run("(fact 30)").unwrap();
drop(interp);
assert_eq!(String::from_utf8(out).unwrap(), "265252859812191058636308480000000\n");
```

Modules: `reader` (text to datums), `analyze` (datums to `Node` trees), `eval`
(the `Interpreter`), `primitives` and `numeric` (built-ins), `bigint`
(`BigInt`), `printer` (write/display forms), `env` (frames), `value`
(`Value`, `Symbol`), `error` (`Error`). Run `cargo doc --open` for the API docs.

Notes: values are `Rc`-based and symbols are interned per thread, so the
interpreter is not `Send`. Recursive Scheme calls recurse on the host stack, so
run deep recursion on a big-stack thread (see `src/main.rs`). Closures that
capture their own frame (named `let`, internal recursive `define`) form
reference cycles and are not reclaimed until the process exits, which is
irrelevant for a run-to-completion interpreter.

## Tests

```sh
cargo test
```

runs unit tests (bignum, reader), end-to-end language tests
(`tests/language.rs`), CLI tests (`tests/cli.rs`) and doc tests. The
problem's example suite is run from the repository root with
`python3 run_tests.py scheme -- scheme/run.sh`.
