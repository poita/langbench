# datalog

A small Datalog engine with stratified negation, written in C++20 with no
dependencies beyond the standard library. It is a reusable library plus a thin
command-line tool: give it a program of facts, rules and queries and it prints
the answers computed from the program's perfect model.

* Bottom-up **semi-naive** evaluation (every tuple is a delta in exactly one
  round; non-linear rules get one variant per recursive atom).
* Safety and stratification checks (Tarjan SCCs over the predicate graph).
* Hash-indexed relations; indexes are maintained incrementally, never rebuilt.
* Constants are interned to their rank in the sorted constant table, so
  comparisons and sorting work on plain integers.
* Language: facts, rules, `not`, comparisons (`< <= > >= = !=`), `_`, integer
  and symbol constants, `?-` queries, `%` comments. Integers sort before
  symbols; symbols sort bytewise.

## Build

Requires a C++20 compiler and CMake ≥ 3.20; GoogleTest is optional (tests are
skipped if `find_package(GTest)` fails).

```sh
./build.sh          # Release build into ./build
build/tests/datalog_tests   # unit tests (or: ctest --test-dir build)
```

## Command line

`run.sh` (or `build/datalog`) reads a program on stdin and writes the answers
to stdout; it takes no arguments.

```sh
$ printf 'edge(1,2). edge(2,3).\npath(X,Y) :- edge(X,Y).\npath(X,Z) :- edge(X,Y), path(Y,Z).\n?- path(1, X).\n' | ./run.sh
path(1, 2)
path(1, 3)
-- 2
```

Each query prints its matching tuples in ascending order, one per line, then
`-- N` with the count. If the program is unsafe or not stratifiable, the output
is just `error`. The exit code is 0 in both cases.

## Library

```
include/datalog/
  ast.h        Constant, Term, Atom, Literal, Rule, Query, Program
  parser.h     parse_program(text) -> Program            (throws ParseError)
  analysis.h   is_safe, check_safety, stratify            (throws ProgramError)
  relation.h   Relation (tuple set) and Index (incremental hash index)
  engine.h     evaluate(Program) -> Model, Model::query, run_program(text)
  datalog.h    umbrella header
src/           implementations (+ main.cpp, the CLI)
tests/         GoogleTest unit tests
```

Example:

```cpp
#include <iostream>
#include "datalog/datalog.h"

int main() {
  using namespace datalog;
  Program program = parse_program(R"(
      edge(a, b). edge(b, c).
      path(X, Y) :- edge(X, Y).
      path(X, Z) :- edge(X, Y), path(Y, Z).
      ?- path(a, X).
  )");

  try {
    Model model = evaluate(program);           // checks safety + stratification
    for (const Query& q : program.queries) {
      for (const Tuple& row : model.query(q.atom))   // sorted
        std::cout << row[0].to_string() << " -> " << row[1].to_string() << "\n";
    }
  } catch (const ProgramError& e) {
    std::cerr << "rejected: " << e.what() << "\n";
  }
}
```

Link against the `datalog::lib` CMake target (`datalog_lib`). `run_program()`
does parse + evaluate + format in one call, as the CLI does.

## Design notes

Rules compile to join plans: the delta atom first, then repeatedly the atom
with the most bound arguments (ties in body order); negations and comparisons
run as soon as their variables are bound. Within a round, atoms of the
component's predicates that precede the delta atom in the body read only
tuples from before the round's delta, later ones read up to the end of the
delta, which gives each derivation exactly once.
