# typeinfer

Hindley-Milner type inference for a small ML-like language, as a C++20 library
plus a command-line tool. It reads a program (a sequence of declarations, each
ended by `;;`) and reports the principal type of every top-level declaration,
or the kind of error (`unify`, `occurs`, `unbound`) for declarations that do
not type-check.

The language has integers, booleans, unit, tuples, lists, first-class
functions, `let` / `let rec` / `fun` / `if` and the usual arithmetic,
comparison and boolean operators. Every `let` is generalised (no value
restriction). The exact grammar and typing rules are in
`problems/typeinfer/SPEC.md`.

## Design

Algorithm J with level-based (Rémy) generalisation:

- types are a shared graph; variables are union-find nodes carrying a level;
- unification is union-find unification with an occurs check that also lowers
  levels; structurally equal constructor nodes are merged, so shared (DAG)
  types unify in time linear in their distinct nodes;
- generalisation quantifies variables above the current level and never scans
  the environment; instantiation copies only the parts containing quantified
  variables and keeps the sharing of the rest;
- the environment keeps one stack of bindings per interned name, so lookup,
  push and pop are O(1) whatever the number of bindings in scope;
- syntax trees and types live in bump-pointer arenas, so deep structures need
  no recursive destructors.

Source layout:

| Module | Files | Responsibility |
| --- | --- | --- |
| lexer | `lexer.hpp`, `src/lexer.cpp` | source text → tokens |
| syntax | `ast.hpp`, `parser.hpp`, `src/parser.cpp`, `symbol.hpp`, `arena.hpp` | tokens → AST, one declaration at a time |
| types | `types.hpp`, `src/types.cpp` | type graph, unify, generalise, instantiate |
| printer | `printer.hpp`, `src/printer.cpp` | canonical rendering of types |
| inference | `environment.hpp`, `inference.hpp`, `src/inference.cpp` | Algorithm J over the AST |
| session | `session.hpp`, `src/session.cpp` | built-ins, whole-program checking, public API |

All headers live in `include/typeinfer/`; `typeinfer/typeinfer.hpp` includes
everything.

## Building

Requires a C++20 compiler and CMake ≥ 3.20; the unit tests need GoogleTest.

```sh
./build.sh                       # Release build into ./build
./build/tests/typeinfer_tests    # unit tests (or: ctest --test-dir build)
```

`build.sh` runs `cmake -S . -B build -DCMAKE_BUILD_TYPE=Release` and builds.
Pass `-DTYPEINFER_BUILD_TESTS=OFF` to skip the tests.

## Command-line use

```sh
./run.sh < program.ml
```

Reads the whole program from stdin and writes one line per declaration:
`name : type` for `let` / `let rec`, `- : type` for a bare expression,
`error: unify|occurs|unbound` for a declaration that fails (it adds nothing to
the environment and processing continues). Type variables are renamed
`'a`, `'b`, … per declaration. Exit status is 0; on malformed input
(unspecified by the language definition) the CLI prints a message to stderr,
stops, and exits with status 1 after printing the results so far.

```
$ printf 'let compose f g x = f (g x);;\nfun x -> x x;;\n(1, [true]);;\n' | ./run.sh
compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b
error: occurs
- : int * bool list
```

The CLI runs the checker on a thread with a 512 MiB stack, because inference
recurses on expression and type depth (inputs nest thousands of levels deep).

## Using the library

Link against the `typeinfer::lib` CMake target (or add `include/` to your
include path and link `libtypeinfer_lib.a`):

```cpp
#include <iostream>
#include "typeinfer/typeinfer.hpp"

int main() {
    typeinfer::Session session;           // starts with the built-ins
    try {
        for (const typeinfer::DeclResult& r :
             session.check("let id = fun x -> x;; (id 1, id true);; fun x -> x x;;")) {
            std::cout << r.to_string() << '\n';
        }
    } catch (const typeinfer::ParseError& e) {
        std::cerr << e.what() << '\n';
    }
}
// id : 'a -> 'a
// - : int * bool
// error: occurs
```

A `Session` keeps its environment between calls to `check`, so it can be used
as a REPL back end. `DeclResult` has `name`, `type` and `error` fields as well
as `to_string()`. Lower-level pieces (`tokenize`, `Parser`, `TypeStore`,
`Inferencer`, `print_type`) are public too; see the headers, which document
their contracts. Deeply nested programs need a large call stack when using the
library directly.
