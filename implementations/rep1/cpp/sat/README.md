# sat

A small, self-contained CDCL SAT solver in C++17 with a reusable library and a
command-line tool that reads DIMACS CNF.

The solver follows the MiniSat design:

- two watched literals (with blocker literals) for unit propagation
- first-UIP conflict analysis with local (one-level) clause minimisation
- VSIDS branching (double-precision activities, decay 0.95 / 0.999) with phase
  saving (initial phase: false)
- Luby restarts, unit 100 conflicts
- periodic deletion of the lower-activity half of the learnt clauses (binary
  ones are kept)
- root-level simplification of input clauses (duplicates, tautologies,
  satisfied clauses, false literals, units)

Only the C++ standard library is used (GoogleTest for the tests).

## Layout

```
include/sat/types.hpp    Var, Lit, LBool
include/sat/heap.hpp     indexed max-heap of variables by activity (VSIDS order)
include/sat/luby.hpp     Luby sequence
include/sat/solver.hpp   the Solver class
include/sat/dimacs.hpp   DIMACS parser (Cnf), loader, answer writer
src/                     implementations
cli/main.cpp             the `sat` command-line tool
tests/                   GoogleTest unit tests
```

## Build

Requires CMake >= 3.20, a C++17 compiler and (for the tests) GoogleTest.

```sh
./build.sh                       # Release build into ./build
# or manually:
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build
ctest --test-dir build           # run the unit tests
```

Options: `-DSAT_BUILD_TESTS=OFF` skips the tests (no GoogleTest needed),
`-DSAT_BUILD_CLI=OFF` skips the tool.

## Command line

```sh
./run.sh < formula.cnf           # same as ./build/sat < formula.cnf
```

Reads DIMACS CNF on standard input and prints either

```
UNSAT
```

or

```
SAT
1 -2 3 0
```

where the second line has one literal per variable `1..V` followed by `0`. The
exit status is 0 for both answers (2 and a message on stderr if the input is
not valid DIMACS).

## Library example

```cpp
#include <iostream>
#include "sat/dimacs.hpp"
#include "sat/solver.hpp"

int main() {
  sat::Solver s;
  s.addClause({1, -2});   // x1 or not x2   (DIMACS-style integers)
  s.addClause({2, 3});    // x2 or x3
  s.addClause({-1, -3});

  if (s.solve() == sat::Result::Sat) {
    for (sat::Var v = 0; v < s.numVars(); ++v)
      std::cout << "x" << v + 1 << " = " << s.modelValue(v) << "\n";
  } else {
    std::cout << "unsatisfiable\n";
  }

  // Parsing DIMACS text:
  sat::Cnf cnf = sat::parseDimacs("p cnf 2 2\n1 2 0\n-1 0\n");
  sat::Solver t;
  sat::loadInto(t, cnf);
  sat::writeResult(std::cout, t.solve(), t.model());
}
```

Link against the `sat::satlib` CMake target (or `add_subdirectory` this
project). `Solver::addClause` simplifies at the root and returns `false` once
the formula is known to be unsatisfiable; `Solver::stats()` exposes conflict,
decision, restart and reduction counters.
