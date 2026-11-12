# langvm

A compiler and stack virtual machine for **Vellum**, a small statically typed
language with modules, structs, sum types with exhaustive pattern matching,
generics, traits, closures, wrapping 64-bit integers, IEEE-754 doubles, lists
and insertion-ordered maps. The language is specified by `SPEC.md` in the
problem directory this project implements; this repository contains only the
implementation.

langvm reads a whole multi-module Vellum program, type-checks it, compiles it to
bytecode and runs it on a stack machine:

```
source text -> tokens -> syntax tree -> items & name resolution
            -> type checking -> bytecode -> execution
```

It is written in D, has no dependencies beyond the D standard library, and is
split into a reusable library plus a thin command-line tool.

## Building

Requirements: LDC 1.41 (or newer) and dub 1.40.

```
./build.sh              # same as: dub build -b release --compiler=ldc2
```

This produces `bin/langvm`. `run.sh` runs it from any directory.

## Command-line use

`langvm` takes no arguments. It reads the *module stream* on stdin and writes
the result to stdout. The exit status is `0` for every outcome described below.

```
$ cat hello.vl
@module main
use util;

fn main() {
    print(util::greet("world"));
}
@module util
pub fn greet(who: Str) -> Str {
    "hello, " ++ who
}
$ ./run.sh < hello.vl
hello, world
```

A program is a sequence of modules, each introduced by a line `@module <name>`.
There are three possible outcomes:

| Outcome | What is printed |
|---|---|
| the program runs to completion | everything it printed with `print` / `emit` |
| it fails at run time | what it printed, then one line `panic: <message>` |
| it does not compile | exactly one line `error: <kind> at <line>:<col>` |

For example, `let n: Int = 1; print(n + "x");` is rejected with
`error: type-mismatch at 3:15`. Line numbers are local to the module (the first
line after the `@module` header is line 1).

## Using the library

The package root, `langvm`, re-exports the public API:

| Symbol | Purpose |
|---|---|
| `compile(input)` | module stream -> `Program` (bytecode); throws `CompileError` |
| `execute(program, sink)` | run a program; output goes to `sink`, a panic appends its `panic:` line |
| `interpret(input, sink)` | compile and run, or emit the single diagnostic line |
| `interpretToString(input)` | like `interpret`, collecting the output in a string |
| `CompileError`, `Kind`, `Pos` | the diagnostic: its kind (`Kind.typeMismatch`, ...) and position |
| `Panic` | the exception a run-time error is represented by inside the VM |

```d
import std.stdio : write;
import langvm;

void main()
{
    enum program = q"VELLUM
@module main
fn fib(n: Int) -> Int { if n < 2 { n } else { fib(n - 1) + fib(n - 2) } }
fn main() { print(showInt(fib(20))); }
VELLUM";

    // One call does everything the command-line tool does:
    write(interpretToString(program));          // 6765

    // Or compile once and inspect errors yourself:
    try
    {
        auto bytecode = compile("@module main\nfn main() { let x: Int = \"s\"; }\n");
        execute(bytecode, (const(char)[] s) { write(s); });
    }
    catch (CompileError e)
    {
        write(e.diagnostic, "\n");               // error: type-mismatch at 1:26
        assert(e.kind == Kind.typeMismatch);
    }
}
```

To depend on langvm from another dub project use the `library` configuration:

```sdl
dependency "langvm" path="../langvm"
subConfiguration "langvm" "library"
```

## Layout

```
source/app.d                 command-line tool (stdin -> stdout)
source/langvm/package.d      public API
source/langvm/driver.d       the compile-and-run pipeline
source/langvm/source.d       splitting the input into modules (pass 0)
source/langvm/lexer.d        tokens (pass 1)
source/langvm/parser.d       recursive descent, precedence climbing (pass 2)
source/langvm/ast.d          syntax tree
source/langvm/types.d        semantic types, unification, declarations
source/langvm/symbols.d      namespaces, imports, signatures, impls (pass 3)
source/langvm/prelude.d      Option/Result and the built-in signatures, in Vellum
source/langvm/bounds.d       Eq / Ord / Key / trait-bound satisfaction
source/langvm/checker.d      bidirectional type checker (pass 4)
source/langvm/patterns.d     usefulness: exhaustiveness and reachability
source/langvm/compiler.d     syntax tree -> bytecode
source/langvm/bytecode.d     instruction set and compiled program
source/langvm/vm.d           the stack machine
source/langvm/value.d        run-time values, lists, insertion-ordered maps
source/langvm/builtins.d     the 132 built-in functions
source/langvm/numfmt.d       exact float printing, number parsing
tests/                       end-to-end tests (spec examples and rule cases)
```

Design notes:

* Every name is resolved once, to an id (function, variant, field, trait, ...);
  nothing is looked up by string at run time. Trait methods are dispatched by
  `(trait, head constructor)` from a table.
* The VM keeps its own call frames, so Vellum recursion depth (limit 20000
  frames) does not use the host stack. Built-ins that call closures
  (`listMap`, `sortBy`, ...) re-enter the VM loop; the tool therefore runs the
  interpreter on a thread with a large stack.
* Strings are arrays of Unicode scalar values, so `charAt` / `strLen` are O(1);
  maps are hash maps over an insertion-ordered entry vector.
* `showFloatAt` is computed with exact integer arithmetic (`std.bigint`), so its
  output is bit-for-bit what a correct `printf("%.*f")` prints.

## Tests

```
dub test --compiler=ldc2
```

runs the unit tests embedded in the library modules (lexer, parser, module
splitting, number formatting, unification, exhaustiveness) and the end-to-end
tests in `tests/`: the seventeen worked examples of the language specification
plus a table of programs covering the language rules, the standard library,
run-time panics and each of the diagnostic kinds.
