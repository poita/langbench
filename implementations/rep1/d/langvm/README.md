# langvm

`langvm` is a compiler and stack virtual machine for **Vellum**, a small statically
typed language with modules, structs, sum types with exhaustive pattern matching,
generic functions, traits, closures, wrapping 64-bit integers, IEEE-754 doubles,
lists, insertion-ordered maps and a 132-function standard library.

The whole pipeline is a library written in D (standard library only):

```
module stream → tokens → AST → items & name resolution → type checking → bytecode → VM
```

A thin command-line tool reads a *module stream* on stdin, compiles it, runs it and
prints either the program's output, a `panic:` line, or a single `error:` diagnostic.

## Building

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh                                  # dub build -b release --compiler=ldc2  →  bin/langvm
dub test --compiler=ldc2                    # unit tests
```

## Command-line use

```sh
./run.sh < program.vel        # or: bin/langvm < program.vel
```

stdin is a sequence of modules, each introduced by an `@module <name>` line:

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

Exactly one of three things is written to stdout (the exit code is always 0):

* **a successful run** – whatever the program printed with `print`/`emit`;
* **a panic** – the output so far followed by `panic: <message>`;
* **a compile error** – one line `error: <kind> at <line>:<col>` and nothing else.

The language is specified in `problems/langvm/SPEC.md` of the task repository; the
design notes (flat bytecode, typed arithmetic opcodes, dense method tables, …) are in
`APPROACH.md`.

## Library layout

| module | responsibility |
|---|---|
| `langvm` (`package.d`) | public API: `runSource`, `compile`, `execute` |
| `langvm.driver` | the pass pipeline and `RunResult` |
| `langvm.diag` | `CompileError`, `Panic`, `Pos` |
| `langvm.source` | splitting the input into modules |
| `langvm.lexer`, `langvm.parser`, `langvm.ast` | tokens, recursive-descent parser, syntax tree |
| `langvm.model` | semantic types, declarations, local variables |
| `langvm.world`, `langvm.resolve` | namespaces, imports, impl registry, `Eq`/`Ord`/`Key`/trait satisfaction, type resolution (passes 3.1–3.6) |
| `langvm.check` | bidirectional type checker with inference variables (pass 4) |
| `langvm.patterns` | usefulness-based exhaustiveness and reachability |
| `langvm.compiler`, `langvm.bytecode` | bytecode generation and instruction set |
| `langvm.vm`, `langvm.value` | the dispatch loop, frames, values, lists and ordered maps |
| `langvm.stdlib`, `langvm.signatures`, `langvm.numfmt` | the built-in functions, their signatures, float/int formatting |

## Using the library

```d
import langvm;
import std.stdio : write;

void main()
{
    enum source = "@module main\n"
        ~ "fn fib(n: Int) -> Int { if n < 2 { n } else { fib(n - 1) + fib(n - 2) } }\n"
        ~ "fn main() { print(showInt(fib(20))); }\n";

    // one call: compile, run, and get the exact stdout text
    auto result = runSource(source);
    write(result.stdout);                       // 6765
    assert(result.outcome == Outcome.finished);

    // or in two steps; compile() throws the single diagnostic as a CompileError
    try
    {
        auto program = compile("@module main\nfn main() { let x: Int = \"s\"; }\n");
        execute(program);
    }
    catch (CompileError e)
    {
        write(e.msg, "\n");                     // error: type-mismatch at 1:26
    }
}
```

`execute` never throws for a panicking program: the panic is reported in
`RunResult.stdout` (`panic: …`) and `RunResult.outcome == Outcome.panicked`.

Deeply nested programs recurse in the parser and checker; the command-line tool therefore
runs the pipeline on a thread with a large stack. Library users who feed deeply nested
source should do the same.

## Tests

* `tests/langvm/*.d` – unit tests (lexer, parser, module splitting, values, number
  formatting, diagnostics, semantics, standard library, and the worked examples of the
  specification), run by `dub test --compiler=ldc2`.
* The end-to-end suite lives with the problem: from the repository root,
  `python3 run_tests.py langvm -- langvm/run.sh`.
