# datalog

A small Datalog engine in C++17 with stratified negation and integer/symbol
comparisons. It is a library (`libdatalog`) plus a command-line tool that reads
a program on stdin and prints the answers to its queries.

* Bottom-up **semi-naive** evaluation: every derived tuple is a delta in exactly
  one round; non-linear rules get one variant per recursive atom.
* Rules are compiled to indexed nested-loop joins (delta atom first, then the
  atom with the most bound arguments). Hash indexes are created per access
  pattern and maintained incrementally.
* Safety and stratification are checked up front (Tarjan SCCs on the predicate
  dependency graph); an unsafe or unstratifiable program is reported as an error.
* Only the C++ standard library is used (GoogleTest for the tests).

## Build

Requires a C++17 compiler, CMake ≥ 3.20 and (for the tests) GoogleTest.

```sh
./build.sh                       # Release build into ./build
# or, by hand:
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build           # run the unit tests
```

CMake options: `-DDATALOG_BUILD_TESTS=OFF`, `-DDATALOG_BUILD_CLI=OFF`.

## Command line

```sh
./run.sh < program.dl            # same as build/datalog < program.dl
```

The whole of stdin is one program of facts, rules and queries:

```prolog
edge(1, 2). edge(2, 3). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
unreachable(X) :- node(X), not path(1, X), X != 1.
node(1). node(2). node(5).
?- path(1, X).
?- unreachable(X).
```

prints, for each query in order, the matching tuples of the model in ascending
order followed by a count line:

```
path(1, 2)
path(1, 3)
path(1, 4)
-- 3
unreachable(5)
-- 1
```

Language summary: constants are integers (`-?[0-9]+`) or lowercase identifiers;
variables start with an upper-case letter; `_` is an anonymous variable; body
literals are atoms, `not atom`, or comparisons (`< <= > >= = !=`). Integers sort
before identifiers, identifiers sort bytewise. `%` starts a comment.

If the program is unsafe (a head/negated/comparison variable that no positive
body atom binds) or not stratifiable (a cycle through negation), the output is
exactly `error`. The exit status is 0 either way. See
`../problems/datalog/SPEC.md` for the full specification.

## Library

Layout (`include/datalog/`, implementations in `src/`):

| module                       | responsibility                                         |
|------------------------------|--------------------------------------------------------|
| `ast.h`                      | `Constant`, `Term`, `Atom`, `Literal`, `Rule`, `Program` |
| `lexer.h`, `parser.h`        | text → `Program`                                       |
| `predicates.h`               | `(name, arity)` → dense `PredId`                       |
| `analysis.h`                 | safety check, stratification (SCCs)                    |
| `value.h`                    | order-preserving integer encoding of constants         |
| `relation.h`                 | append-only tuple sets with incremental hash indexes   |
| `plan.h`                     | rule → join plan (and semi-naive variants)             |
| `evaluator.h`                | semi-naive fixpoint of one component                   |
| `engine.h`                   | `Engine`: analysis + evaluation + queries              |
| `datalog.h`                  | umbrella header, `run_program`, `format_answer`        |

Example:

```cpp
#include <iostream>
#include "datalog/datalog.h"

int main() {
  using namespace datalog;
  Program program = parse_program(R"(
    parent(ann, bob). parent(bob, cid). parent(cid, dee).
    ancestor(X, Y) :- parent(X, Y).
    ancestor(X, Z) :- parent(X, Y), ancestor(Y, Z).
  )");

  try {
    Engine engine(program);            // checks the program and computes the model

    Atom query;                        // ?- ancestor(ann, X).
    query.predicate = "ancestor";
    query.args = {Term::constant(Constant::symbol("ann")), Term::variable("X")};

    for (const Tuple& row : engine.query(query))
      std::cout << row[0].to_string() << " -> " << row[1].to_string() << "\n";
  } catch (const ProgramError& e) {      // unsafe or not stratifiable
    std::cerr << e.what() << "\n";
  }
}
```

Link against the `datalog::datalog` CMake target. `parse_program` throws
`ParseError` on malformed text; `Engine`'s constructor throws `ProgramError`
for unsafe or unstratifiable programs. `run_program(text)` does everything the
CLI does and returns the output string.

## Tests

`tests/` holds GoogleTest suites for the parser/lexer, the analyses, the
relation/index structures and the engine (including the examples from the
spec, non-linear and mutual recursion, negation and ordering). The end-to-end
problem tests are run with `run_tests.py` from the parent directory.
