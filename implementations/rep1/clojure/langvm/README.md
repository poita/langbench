# langvm

A compiler and stack virtual machine for **Vellum**, a small statically typed
language with modules, structs, sum types with exhaustive pattern matching,
generic functions, traits, closures, wrapping 64-bit integers, IEEE-754
doubles, lists, insertion-ordered maps and a 132-function standard library.
The language is defined by [`problems/langvm/SPEC.md`](../problems/langvm/SPEC.md);
this project is a standalone Clojure implementation of that specification,
written against only the Clojure standard library.

`langvm` reads a *module stream* on stdin, type checks it, compiles it to
bytecode and runs it.  Exactly one of three things reaches stdout:

* the program's own output (`print` / `emit`),
* that output followed by one `panic: <message>` line when the program
  panics at run time, or
* a single `error: <kind> at <line>:<col>` line when the program is rejected.

The exit code is always 0 for these outcomes.

## Requirements

* Java 27 (any recent JDK should work)
* the [Clojure CLI](https://clojure.org/guides/install_clojure) with Clojure 1.12.6

## Build

```sh
./build.sh
```

`build.sh` AOT-compiles the sources into `classes/` (so start-up does not pay
for compiling Clojure) and records the runtime classpath in `.classpath`.  It
can be run from any directory.

## Command-line usage

```sh
./run.sh < program.vl
```

`run.sh` also works from any directory.  A program is one or more modules;
every module starts with an `@module <name>` line and the module named `main`
must declare `fn main()`:

```
@module main
use util;

fn main() {
    print(util::greet("world"));
}
@module util
pub fn greet(who: Str) -> Str {
    "hello, " ++ who
}
```

```
$ ./run.sh < hello.vl
hello, world
```

```
$ printf '@module main\nfn main() { let n: Int = 1; print(n + "x"); }\n' | ./run.sh
error: type-mismatch at 1:39
$ printf '@module main\nfn main() { print("a"); panic("boom"); }\n' | ./run.sh
a
panic: boom
```

Without building you can also use `clojure -M:run < program.vl`.

## Library usage

The compiler is a reusable library; the command-line tool is a thin wrapper
around `langvm.core`.

```clojure
(require '[langvm.core :as langvm]
         '[langvm.diag :as diag])

;; One call: compile and run, collecting the output in a string.
(langvm/run-string "@module main\nfn main() { print(showInt(6 * 7)); }\n")
;; => "42\n"

;; In stages, with your own output stream.
(let [compiled (langvm/compile-source
                 "@module main\nfn main() { print(\"hi\"); panic(\"boom\"); }\n")
      out      (java.io.ByteArrayOutputStream.)
      panic    (langvm/run-compiled compiled out)]   ; => "boom"
  (.toString out "UTF-8"))
;; => "hi\npanic: boom\n"

;; Rejected programs throw a diagnostic.
(try
  (langvm/compile-source "@module main\nfn main() { let x: Int = \"s\"; }\n")
  (catch clojure.lang.ExceptionInfo e
    (when (diag/diagnostic? e)
      (diag/format-diag e))))
;; => "error: type-mismatch at 1:26"
```

Public entry points of `langvm.core`:

| function | purpose |
|---|---|
| `parse-source` | passes 0-2: split, lex and parse a module stream |
| `check-source` | passes 0-4: also build the program model and type check |
| `compile-source` | everything up to bytecode (throws a diagnostic on error) |
| `run-compiled` | run a compiled program against an `OutputStream`; returns the panic message or `nil` |
| `execute` | compile and run, writing output, panic line or diagnostic to a stream; returns `:ok`, `:panic` or `:error` |
| `run-string` | `execute` into a string |

## Architecture

The pipeline follows SPEC section 16: source text, tokens, AST, items and
name resolution, type checking, bytecode, execution.  Each stage is its own
namespace under `src/langvm/`:

| namespace | responsibility |
|---|---|
| `langvm.source` | splitting the input into modules (`bad-module`, `dup-module`) |
| `langvm.lexer` | tokens, nested comments, numeric literals, escapes, positions |
| `langvm.parser` | recursive descent with precedence climbing, producing the AST |
| `langvm.program` | pass 3: namespaces, `use`, type resolution, trait/impl registry, `Eq`/`Ord`/`Key` and bound satisfaction |
| `langvm.names` | resolution of value paths and struct paths |
| `langvm.types` | semantic types, inference variables, unification with occurs check |
| `langvm.patterns` | pattern typing, irrefutability, the usefulness algorithm (exhaustiveness and reachability, including the list rule) |
| `langvm.check` | bidirectional type checker (pass 4); produces an IR with resolved names and type-specialised operators |
| `langvm.bytecode` | the instruction set |
| `langvm.compile` | IR to bytecode: slots, closures, pattern matching, loops |
| `langvm.runtime` | run-time value representation, structural equality and ordering |
| `langvm.stdlib` | the 132 built-ins; their signatures are written in Vellum syntax and parsed by the front end |
| `langvm.numfmt` | `showFloatAt`, radix printing, `parseInt`, `parseFloat` |
| `langvm.vm` | the stack machine: a flat interpreter loop with its own frame arrays, so Vellum call depth (limit 20000) never touches the JVM stack |
| `langvm.core` | the public API |
| `langvm.cli` | the command-line tool |
| `langvm.diag` | diagnostics (kinds, positions, formatting) |

Notable representation choices: `Int` is a `Long`, `Float` a `Double`, `Char`
an `Integer` holding the scalar value and `Str` a `VStr` that caches its length
in scalar values (so `strLen` and `charAt` are O(1) for BMP text); lists are
`ArrayList`s and maps are `LinkedHashMap`s (insertion ordered).  Trait method
calls dispatch in O(1) through a table indexed by trait and head constructor.

## Tests

```sh
clojure -M:test
```

runs the project's own tests with the Cognitect test runner: unit tests per
module, a table of programs for each diagnostic kind, the worked examples of
SPEC section 17 (`test/resources/spec-examples`), `test.check` properties for
the standard library, and, when `../problems/langvm/tests` exists (or
`LANGVM_TESTS` points at a suite), the whole conformance suite.

The conformance suite can also be run against the built tool:

```sh
cd .. && langvm/build.sh && python3 run_tests.py langvm -- langvm/run.sh
```
