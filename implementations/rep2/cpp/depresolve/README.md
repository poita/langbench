# depresolve

A small C++20 library and command-line tool that resolves package dependencies
using a fully specified search: depth-first, newest version first, with
chronological backtracking. Given a registry (every version of every package
with its requirements) and a root manifest, it picks one version per needed
package, or reports `unsatisfiable`. Because the search order is fixed, the
output is deterministic: it is the *first* solution that search finds, not a
globally "best" one.

Supported ranges follow npm semantics: `*`, exact `X.Y.Z`, caret `^X.Y.Z`,
tilde `~X.Y.Z`, and sets of comparators (`>=1.0.0 <2.0.0`). Versions are plain
`MAJOR.MINOR.PATCH` and compare numerically.

## Layout

| Path | Contents |
|---|---|
| `include/depresolve/version.hpp`, `src/version.cpp` | `Version`: parsing, ordering, formatting |
| `include/depresolve/range.hpp`, `src/range.cpp` | `Range`: a half-open version interval; `*`, exact, caret, tilde, comparators |
| `include/depresolve/registry.hpp`, `src/registry.cpp` | `Registry`: packages, versions sorted newest first, requirements compiled to candidate index ranges by binary search |
| `include/depresolve/parser.hpp`, `src/parser.cpp` | Text format → `Problem` (registry + root requirements) |
| `include/depresolve/resolver.hpp`, `src/resolver.cpp` | The iterative backtracking search and output formatting |
| `include/depresolve/depresolve.hpp` | Umbrella header |
| `cli/main.cpp` | The `depresolve` executable: stdin → stdout |
| `tests/` | GoogleTest unit tests |
| `examples/library_usage.cpp` | Library example |

## Build

Requires a C++20 compiler and CMake ≥ 3.20. GoogleTest is optional (tests are
skipped with a warning if `find_package(GTest)` fails).

```sh
./build.sh                 # Release build in ./build
./build/tests/depresolve_tests   # or: (cd build && ctest)
```

`build.sh` is equivalent to:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

CMake options: `-DDEPRESOLVE_BUILD_TESTS=OFF`, `-DDEPRESOLVE_BUILD_EXAMPLES=OFF`.
The library installs with `cmake --install build` and exposes the target
`depresolve::depresolve` when used via `add_subdirectory`.

## Command-line use

`./run.sh` (or `build/depresolve`) reads the whole input on stdin and writes
the resolution to stdout. The input is zero or more registry lines followed by
one root line:

```
a 1.0.0: c ^1.0.0
b 1.0.0: c ~1.2.0
c 1.1.0:
c 1.2.5:
c 1.3.0:
root: a *, b *
```

```
$ ./run.sh < input.txt
a 1.0.0
b 1.0.0
c 1.2.5
```

Output is one `name version` line per chosen package, sorted by name in byte
order, or the single line `unsatisfiable` (exit status 0 in both cases). An
empty root produces no output. Malformed input is reported on stderr with exit
status 2.

The full format and search definition are in `problems/depresolve/SPEC.md` of
the surrounding repository.

## Library use

```cpp
#include <iostream>
#include "depresolve/depresolve.hpp"

int main() {
  using namespace depresolve;

  // Either parse the text format...
  Problem problem = parse_problem("a 1.0.0: b ^1.0.0\nb 1.2.0:\nb 1.3.0:\nroot: a *\n");
  std::cout << format_resolution(resolve(problem));   // a 1.0.0 / b 1.3.0

  // ...or build a registry in code.
  Registry registry;
  registry.add_version("a", *Version::parse("1.0.0"), {{"c", *Range::parse("^1.0.0")}});
  registry.add_version("c", *Version::parse("1.4.0"), {});
  registry.finalize();                                 // sort + compile requirements

  Resolution r = resolve(registry, {{"a", Range::any()}});
  if (r.satisfiable)
    for (const Pick& p : r.picks) std::cout << p.name << ' ' << p.version.to_string() << '\n';
}
```

A complete program is in `examples/library_usage.cpp`.

Key types: `Version`, `Range` (`Range::parse`, `contains`), `Registry`
(`add_version`, `finalize`, `compile`), `Problem`, `parse_problem`,
`Resolution` (`satisfiable`, `picks`, `stats`), `resolve`, `format_resolution`,
`resolve_text`. A `Registry` must be `finalize()`d before resolving; the
resolver throws `std::logic_error` otherwise. `parse_problem` throws
`ParseError` (with the line number) on malformed input.

## Design notes

- Each range is a half-open interval `[lo, hi)`. After versions are sorted
  newest first, every requirement is turned once into the contiguous index
  range of candidate versions by binary search, so the search never scans.
- The search is iterative (no recursion), so the ~10,000-deep pending lists of
  large registries are not limited by the call stack. Pending requirements are
  a linked list whose tails are shared between choice points and live in an
  arena that is truncated on backtracking; chosen versions are undone via the
  choice-point stack. A step costs O(1) plus the requirements it pushes.
- No backjumping, learning, reordering or pruning: the output must equal the
  specified first solution.
