# langvm

`langvm` is a compiler and stack virtual machine for **Vellum**, a small
statically typed language with modules, structs, sum types with exhaustive
pattern matching, generic functions, traits with implementations, closures,
64-bit wrapping integers, IEEE-754 doubles with an exactly specified printing
rule, lists, insertion-ordered maps and a 132-function standard library. The
language is defined in `SPEC.md` of the problem this project implements; the
code follows it section by section.

It is a Go library with a thin command-line tool on top. Only the Go standard
library is used.

## Build

Go 1.27 or newer is required.

```sh
./build.sh          # builds bin/langvm
go test ./...       # runs the unit and golden tests
```

`build.sh` and `run.sh` work from any directory.

## Command-line use

`langvm` reads a whole program — a *module stream* — on standard input and
writes the program's output on standard output. It takes no arguments and
always exits with status 0.

```sh
./run.sh < program.vl
```

A module stream is a sequence of `@module <name>` header lines, each followed
by that module's source. The module `main` must declare `fn main()`:

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

prints `hello, world`. There are three possible outcomes:

* **success** — whatever the program printed with `print` and `emit`;
* **compile error** — exactly one line, `error: <kind> at <line>:<col>`, and
  nothing else (the program is not run);
* **panic** — the output printed so far, followed by `panic: <message>`.

## Library use

```go
package main

import (
	"fmt"
	"os"

	"langvm"
)

func main() {
	src := []byte(`@module main
fn fib(n: Int) -> Int { if n < 2 { n } else { fib(n - 1) + fib(n - 2) } }
fn main() { print(showInt(fib(20))); }
`)

	prog, diagnostic := langvm.Compile(src)
	if diagnostic != nil {
		fmt.Println(diagnostic) // error: <kind> at <line>:<col>
		return
	}
	if err := prog.Run(os.Stdout); err != nil {
		fmt.Println(err) // panic: <message>
	}
}
```

`langvm.Compile` returns a `*langvm.Diagnostic` (an `error`) for a rejected
program, `Program.Run` returns a `*langvm.Panic` for a run-time panic, and
`langvm.Run` does both steps at once.

## Layout

The pipeline is *source → tokens → syntax tree → names and types → bytecode →
execution*, one package per stage:

| Package | Responsibility |
|---|---|
| `langvm` (root) | public API: `Compile`, `Program.Run`, `Run` |
| `cmd/langvm` | the command-line tool |
| `diag` | the diagnostic kinds and the `Error` type |
| `source` | splitting the input into modules (`bad-module`, `dup-module`) |
| `lexer` | tokens, nested comments, numeric and string literals |
| `ast` | the syntax tree, annotated in place by the checker |
| `parser` | recursive descent with precedence climbing |
| `types` | semantic types, unification, declarations, traits, impls |
| `builtins` | the table of the 132 built-ins and their signatures |
| `check` | namespaces, type resolution, bidirectional inference, trait resolution, patterns and the usefulness-based exhaustiveness check |
| `bytecode` | the instruction set and program representation |
| `compiler` | code generation from the checked tree |
| `vm` | the interpreter loop, values, maps and the built-in implementations |
| `numfmt` | exact float printing, integer and float parsing |

Design points worth knowing:

* The VM has its own frame stack, so Vellum call depth (limit 20000 frames)
  does not use host recursion. Only built-ins that call closures (`listMap`,
  `sortBy`, …) re-enter the interpreter loop.
* Every name is resolved once by the checker; the compiler and VM use ids
  (function indices, declaration ids, trait ids, built-in ids) and never look
  anything up by name at run time.
* `CALL_METHOD` finds its implementation in O(1) from the trait and the
  receiver's head constructor.
* Strings are `[]rune`, so `charAt` and `strLen` are O(1); maps are hash maps
  over an insertion-ordered entry slice.
* The checker reports the first error in the pass order of the specification
  by aborting with the first diagnostic.

## Tests

`go test ./...` runs table-driven tests per package and a golden-file suite:
every `testdata/NAME.in` program is run and its output compared with
`testdata/NAME.out`.
