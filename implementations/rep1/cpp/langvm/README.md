# langvm

`langvm` is a compiler and stack virtual machine for **Vellum**, a small
statically typed language with modules, structs, sum types with exhaustive
pattern matching, generic functions, traits with implementations, closures,
wrapping 64-bit integers, IEEE-754 doubles and insertion-ordered maps. The
language is defined by [`problems/langvm/SPEC.md`](../problems/langvm/SPEC.md);
this project is a C++20 implementation of it, written against the standard
library only (GoogleTest is used for the tests).

It is a real compiler pipeline: source text → tokens → syntax tree → name
resolution → bidirectional type checking (with exhaustiveness analysis) →
bytecode → a fetch-decode-execute VM with its own call frames, so Vellum
recursion depth is not limited by the host stack.

## Building

Requirements: a C++20 compiler (developed with Apple clang 21), CMake ≥ 3.20,
and GoogleTest if you want the tests.

```sh
./build.sh            # Release build into ./build (library, CLI, tests)
LANGVM_BUILD_TESTS=OFF ./build.sh   # skip the tests (no GoogleTest needed)
```

or by hand:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build        # or ./build/langvm_tests
```

## Command-line use

The CLI reads one *module stream* on stdin and writes to stdout. It takes no
arguments and always exits 0.

```sh
./run.sh < program.vel
```

A module stream is a sequence of modules, each introduced by a header line
`@module <name>`; the program starts at `fn main()` in module `main`:

```
@module main
use util;

fn main() {
    print(util::greet("world"));
}
@module util
pub fn greet(who: Str) -> Str { "hello, " ++ who }
```

Exactly one of three things is printed:

| Situation | Output |
|---|---|
| the program is rejected | one line, `error: <kind> at <line>:<col>` |
| it runs to completion | whatever it printed with `print` / `emit` |
| it panics | its output so far, then `panic: <message>` |

## Using the library

```cpp
#include <iostream>
#include <string>
#include "langvm/langvm.h"

int main() {
  const std::string source =
      "@module main\n"
      "fn fib(n: Int) -> Int { if n < 2 { n } else { fib(n - 1) + fib(n - 2) } }\n"
      "fn main() { print(showInt(fib(20))); }\n";

  langvm::CompileResult compiled = langvm::compile(source);
  if (!compiled.ok()) {
    std::cout << compiled.diagnostic->toString() << "\n";  // e.g. "error: type-mismatch at 2:30"
    return 1;
  }
  langvm::RunResult result = langvm::run(*compiled.program, std::cout);  // prints 6765
  return result.panicked ? 2 : 0;  // result.panicMessage holds the panic text
}
```

Link against the `langvm` target (`target_link_libraries(app PRIVATE langvm)`).
The public API is two headers in `include/langvm/`:

* `langvm.h` — `compile`, `run`, `execute` (compile + run, as the CLI does),
  and the opaque `Program` handle;
* `diagnostic.h` — `Diagnostic`, `ErrorKind` and `kindName` for the 51
  diagnostic kinds.

A compiled `Program` is immutable and can be run any number of times.

## Layout

```
include/langvm/   public API (langvm.h, diagnostic.h)
src/
  source.*        pass 0: splitting the input into modules
  lexer.*         pass 1: tokens, positions, literals
  ast.h parser.*  pass 2: recursive-descent parser
  types.*         semantic types, unification with occurs check
  model.h         modules, declarations, traits, impls, signatures
  resolver.*      pass 3: namespaces, imports, signatures, impl coherence
  traits.*        Eq / Ord / Key and user-trait satisfaction
  checker.*       pass 4: statements, blocks, divergence
  check_expr.cpp  pass 4: bidirectional expression rules, generic calls
  check_pattern.cpp, exhaustive.cpp   patterns, usefulness algorithm
  compiler.*      bytecode generation (bytecode.h defines the instruction set)
  value.* vm.*    runtime values, the interpreter loop, panics
  builtins.cpp    the 132 standard-library functions
  builtin_sigs.cpp  their signatures, written in Vellum and parsed by the front end
  numfmt.*        float printing, int/float parsing
  api.cpp         compile / run / execute
tools/main.cpp    the CLI
tests/            GoogleTest suites
```

Design notes:

* Names are resolved once, to ids; neither the checker, the compiler nor the VM
  looks anything up by string at run time. Trait method calls dispatch in O(1)
  on `(trait, head constructor)`.
* Strings are `char32_t` sequences, so `charAt`/`strLen` are O(1). Maps are
  insertion-ordered hash maps with tombstones. Lists and maps are reference
  counted; freeing is iterative so very long chains cannot overflow the host
  stack.
* Compile errors are reported in the pass order of the specification (module
  split, lex, parse, items, bodies); the first error found wins.
* Floating-point code is built with `-ffp-contract=off` so no fused
  multiply-adds can change a result.

## Tests

`./build/langvm_tests` (also registered with CTest) runs:

* `test_lexer.cpp` — tokens, literal edge cases, module splitting;
* `test_diagnostics.cpp` — every diagnostic kind with its exact position, and
  pass-ordering rules;
* `test_programs.cpp` — whole programs: arithmetic, panics, closures, traits,
  patterns, evaluation order, deep recursion and data;
* `test_stdlib.cpp` — the standard library, section by section.

The repository-level conformance suite runs the CLI against the example
programs:

```sh
cd .. && python3 run_tests.py langvm -- langvm/run.sh
```
