# langvm

`langvm` is a compiler and stack virtual machine for **Vellum**, a small
statically typed language with modules, structs, sum types with exhaustive
pattern matching, generics, traits, closures, 64-bit wrapping integers, exactly
specified float printing and a 132-function standard library.

It reads a *module stream* on stdin, compiles it to bytecode, and runs it:

* a program that does not compile prints exactly one line,
  `error: <kind> at <line>:<col>`;
* a program that compiles prints whatever it prints, followed – if it hits a
  run-time error – by one `panic: <message>` line;
* the exit status is always `0`.

Only the Python standard library is used (Python 3.14).

## Build

There is no install step. `build.sh` byte-compiles the package so start-up is
fast; `run.sh` runs the package with `PYTHONPATH` pointing at `src/`.

```sh
./build.sh
```

## Command line

```sh
./run.sh < program.vl
```

stdin is a stream of modules, each introduced by an `@module <name>` line:

```
@module main
use util;

fn main() {
    print(util::greet("world"));
}
@module util
pub fn greet(who: Str) -> Str { "hello, " ++ who }
```

```
$ ./run.sh < hello.vl
hello, world
```

```
$ printf '@module main\nfn main() { let n: Int = 1; print(n + "x"); }\n' | ./run.sh
error: type-mismatch at 1:39
```

Equivalent invocations: `python3 -m langvm < program.vl` with `PYTHONPATH=src`,
or `langvm < program.vl` after `pip install .`.

## Library

```python
from langvm import CompileError, Panic, VM, compile_program, run_source

# One call: compile, run, and get the exact stdout text.
result = run_source('@module main\nfn main() { print("hi"); }\n')
assert result.output == "hi\n" and result.panic is None and result.error is None

# Or drive the phases yourself.
source_text = '@module main\nfn main() { print(showInt(1 + 2)); }\n'
try:
    image = compile_program(source_text)          # -> langvm.Image (bytecode)
except CompileError as e:
    print(e.kind, e.line, e.col)                  # e.g. "type-mismatch 3 15"
else:
    out: list[str] = []
    try:
        VM(image, out).run()
    except Panic as p:
        print("panicked:", p.message)
    print("".join(out))
```

`run_source` runs on a worker thread with a large stack and a raised recursion
limit (deeply nested programs and values recurse in the front end and in
structural equality); `compile_program` and `VM` do not change interpreter
settings.

## Layout

```
src/langvm/
  source.py      module-stream splitting, bad-module / dup-module
  lexer.py       tokens (regex driven; nested comments, escapes, number forms)
  syntax.py      syntax tree (dataclasses; checker annotations live in the nodes)
  parser.py      recursive descent + precedence climbing
  types.py       semantic types, inference variables, unification
  program.py     declaration records and whole-program tables
  prelude.py     Option/Result, built-in traits, the 132 built-in signatures
  resolve.py     type/trait/path resolution (arity, Key, Self, visibility)
  items.py       item passes 3.1-3.6: declarations, imports, signatures, impls
  traits.py      Eq/Ord/Key and user-trait satisfaction (impl lookup)
  patterns.py    usefulness algorithm: exhaustiveness, reachability, irrefutability
  checker.py     bidirectional type checker; resolves every name to an object
  ops.py         the instruction set
  compiler.py    annotated tree -> bytecode (closures, match, loops, patterns)
  vm.py          flat fetch-decode-execute loop with its own frame stack
  stdlib.py      the built-in functions
  floatfmt.py    fixed-point float printing
  api.py cli.py  public API and the command-line tool
tests/           pytest suite
```

Pipeline: source text → tokens → syntax tree → items and name resolution →
type checking (which annotates the tree) → bytecode → execution. Nothing is
looked up by name after resolution, and the VM never recurses on the host stack
for Vellum calls, so the 20000-frame limit is exact (built-ins that call
closures, such as `listMap` or `sortBy`, re-enter the VM but share its frame
accounting).

### Run-time representation

| Vellum | Python |
|---|---|
| `Int` / `Float` / `Bool` / `Str` | `int` (wrapped to 64 bits) / `float` / `bool` / `str` |
| `Char` | `Char`, a one-scalar `str` subclass (so traits can tell it from a `Str`) |
| `Unit` | `None` |
| list / map | `list` / insertion-ordered `dict` |
| tuple | `tuple` |
| struct, enum value | `tuple` whose element 0 is the declaration's / variant's unique id |
| closure | `Closure(code, captured values)` |

Equality compiles to Python's `==` where that is exact, and to a structural
helper (`values.veq`) where a `Float` (NaN) or a generic type could be inside.

## Tests

```sh
PYTHONPATH=src python3 -m pytest tests
```

The suite covers module splitting, the lexer, the parser, the usefulness
algorithm, diagnostics (kind and exact position), run-time semantics and
panics, the standard library, and the CLI contract.
