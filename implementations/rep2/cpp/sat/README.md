# sat

A small, dependency-free CDCL SAT solver for DIMACS CNF, written in C++17.
It is a library (`sat_core`) plus a thin command-line tool (`sat`).

Algorithm (MiniSat style): two-watched-literal unit propagation, first-UIP
clause learning with local clause minimisation, VSIDS branching with phase
saving (initially false), Luby restarts (unit 100 conflicts) and
activity-based deletion of half the learnt clauses after restarts once
`max_learnts` is reached (binary and reason clauses are kept).
Input clauses are simplified at the root (duplicates, tautologies, satisfied
clauses, false literals; units are propagated).

## Layout

| Path | Contents |
| --- | --- |
| `include/sat/types.hpp` | `Var`, `Lit`, `LBool`, `Result` |
| `include/sat/heap.hpp`, `src/heap.cpp` | `VarHeap`, the activity-ordered priority queue |
| `include/sat/solver.hpp`, `src/solver.cpp` | `Solver`, `Stats`, `luby()` |
| `include/sat/dimacs.hpp`, `src/dimacs.cpp` | DIMACS parser (`Cnf`, `parse_dimacs`), `load`, `satisfies`, `write_result` |
| `cli/main.cpp` | the `sat` executable |
| `tests/` | GoogleTest unit tests |

## Build

Requires a C++17 compiler and CMake >= 3.20; GoogleTest is optional (tests are
skipped if `find_package(GTest)` fails, or pass `-DSAT_BUILD_TESTS=OFF`).

```sh
./build.sh            # Release build into ./build
./build/sat_tests     # or: (cd build && ctest)
```

## Command line

```sh
./run.sh < problem.cnf
```

Reads DIMACS CNF on stdin. Prints `UNSAT`, or `SAT` followed by a line
`l1 l2 ... lV 0` with one literal per variable. Exit status is 0 for both
answers (2 on a parse error, with a message on stderr).

```
$ printf 'p cnf 3 2\n1 -2 0\n2 3 0\n' | ./run.sh
SAT
-1 -2 3 0
```

## Library example

```cpp
#include <iostream>
#include "sat/dimacs.hpp"
#include "sat/solver.hpp"

int main() {
    // From a DIMACS string:
    sat::Cnf cnf = sat::parse_dimacs("p cnf 3 2\n1 -2 0\n2 3 0\n");
    sat::Solver solver;
    if (sat::load(solver, cnf) && solver.solve() == sat::Result::Sat) {
        std::cout << "satisfies: " << sat::satisfies(cnf, solver.model()) << '\n';
    }

    // Or build a formula directly: (a OR NOT b) AND (b)
    sat::Solver s;
    sat::Var a = s.new_var(), b = s.new_var();
    s.add_clause({sat::Lit(a), sat::Lit(b, /*negative=*/true)});
    s.add_clause({sat::Lit(b)});
    if (s.solve() == sat::Result::Sat)
        std::cout << "a=" << s.model_value(a) << " b=" << s.model_value(b) << '\n';
}
```

Link against the `sat::core` CMake target (`target_link_libraries(app PRIVATE sat::core)`).
`Solver::add_clause` returns `false` once the formula is known unsatisfiable;
`Solver::solve` should be called once, after all clauses are added.
