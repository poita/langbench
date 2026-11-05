# langvm

`langvm` is a compiler and stack virtual machine for **Vellum**, a small
statically typed language with modules, structs, sum types with exhaustive
pattern matching, generics with trait bounds, traits and impls, closures,
64-bit wrapping integers, IEEE-754 floats with an exact printing rule, lists,
insertion-ordered maps and a 132-function standard library. The language is
defined by [`problems/langvm/SPEC.md`](../problems/langvm/SPEC.md).

It reads a multi-module program on standard input, type-checks it, compiles it
to bytecode and runs it:

```
source text → modules → tokens → AST → name resolution + type checking
            → bytecode → switch-dispatched stack VM
```

Only the Go standard library is used.

## Building

Requires Go 1.27.1.

```sh
./build.sh          # builds ./bin/langvm (works from any directory)
go test ./...       # runs the unit tests
```

`run.sh` runs the built binary (`./run.sh < program.vel`).

## Command-line use

```sh
./run.sh < program.vel
```

The whole of stdin is a *module stream*: a sequence of `@module <name>` header
lines, each followed by that module's source. `main` in module `main` is run.

```
@module main
use greet;

fn main() {
    print(greet::hello("Vellum"));
}
@module greet
pub fn hello(who: Str) -> Str { "hello, " ++ who ++ "!" }
```

prints `hello, Vellum!`. The exit status is always 0, and exactly one of these
happens:

| Situation | stdout |
|---|---|
| the program runs | what it printed with `print`/`emit` |
| the program panics at run time | what it printed, then `panic: <message>` |
| the program does not compile | one line, `error: <kind> at <line>:<col>` |

Anything written to stderr is diagnostics about the tool itself (for example an
unreadable stdin) and is not part of the contract.

## Library

The command is a thin wrapper over the packages below; each stage can be used on
its own.

| Package | Responsibility |
|---|---|
| `langvm/diag` | the single compile-time diagnostic (kind + position) |
| `langvm/lexer` | module body → tokens (nested comments, numeric literals, escapes) |
| `langvm/ast` | syntax tree; annotation slots filled in by the checker |
| `langvm/parser` | recursive-descent parser with precedence climbing |
| `langvm/builtins` | names and signatures of the 132 built-in functions |
| `langvm/check` | namespaces, imports, types, traits and impls, bidirectional inference with unification, pattern usefulness/exhaustiveness |
| `langvm/bytecode` | instruction set and compiled-program format |
| `langvm/compile` | checked AST → bytecode (slots, closures, match compilation) |
| `langvm/vm` | value representation, interpreter loop, insertion-ordered maps, the standard library |
| `langvm/vellum` | the facade: module splitting and the whole pipeline |

### Example

```go
package main

import (
	"fmt"

	"langvm/vellum"
)

func main() {
	src := []byte(`@module main
fn fib(n: Int) -> Int { if n < 2 { n } else { fib(n - 1) + fib(n - 2) } }
fn main() { print(showInt(fib(20))); }
`)

	// One call: compile and run, getting exactly what the CLI would print.
	fmt.Print(string(vellum.Run(src))) // 6765

	// Or stage by stage, to handle diagnostics yourself:
	prog, err := vellum.Compile(src)
	if err != nil {
		fmt.Println(err.Kind, err.Pos.Line, err.Pos.Col)
		return
	}
	fmt.Println(len(prog.Funcs), "functions compiled")
}
```

`vellum.Check` stops after type checking and returns the annotated
`*check.Program`; `vellum.SplitModules` implements pass 0 alone.

## Design notes

* Every pass reports the first error in the order fixed by SPEC section 13
  (lex everything, then parse everything, then items in six sub-passes, then
  function bodies), so the diagnostic is identical to every conforming
  implementation's.
* Names are resolved once; the checker stores the result (locals, functions,
  variants, trait methods) on the AST nodes and the compiler never looks up a
  string.
* Inference uses mutable type variables bound at most once (unification with
  an occurs check); generic calls instantiate fresh variables for their type
  parameters. Exhaustiveness and reachability use the usefulness algorithm of
  SPEC 12.4 directly on each `match`.
* Bytecode has typed arithmetic (`ADD_I` vs `ADD_F`), slot-based fused match
  tests, fused loop forms, and a dense `[trait][head constructor]` method
  table for dispatch.
* The VM is one `switch` loop over a preallocated value stack and a 20000-frame
  array; Vellum calls never recurse on the Go stack. Built-ins that take
  closures re-enter the same loop.
* Values are 16-byte cells (`int64` payload plus a pointer to a heap object or
  a shared per-kind tag); strings are arrays of scalar values; maps are an
  entry vector plus an open-addressing index.
* Output is collected in one buffer and written once at the end.

## Testing

* `go test ./...` runs the package tests, the worked examples of SPEC section
  17 (`vellum/testdata`), and — when the repository layout is present — the
  complete problem suite under `problems/langvm/tests`.
* From the repository root: `python3 run_tests.py langvm -- langvm/run.sh`.

## Notes on the specification

* SPEC 9.4 applies the expected type of a generic call only *after* its
  arguments are checked, so an argument such as `Ok(4)` nested in
  `Some(Ok(4))` is `cannot-infer` even when the whole expression is checked
  against `Option<Result<Int, Str>>`. This is implemented as written.
