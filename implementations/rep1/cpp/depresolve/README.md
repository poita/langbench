# depresolve

A small C++20 library and command-line tool that resolves package
dependencies deterministically. Given a registry (every version of every
package with its requirements) and a root manifest, it picks one version per
needed package using a fixed search: depth-first, newest version first,
chronological backtracking. It prints the first complete solution found, or
`unsatisfiable`. Ranges follow npm semantics (`*`, exact, `^`, `~`, and
`<`/`<=`/`>`/`>=` comparator conjunctions). There are no dependencies beyond
the standard library (GoogleTest for the tests).

## Layout

| Path | Contents |
|---|---|
| `include/depresolve/version.hpp` | `Version` (numeric ordering, parse/format) |
| `include/depresolve/range.hpp` | `Range`: any range normalised to `[lo, hi)` |
| `include/depresolve/registry.hpp` | `Registry`, `PackageVersion`, `Requirement` |
| `include/depresolve/parser.hpp` | `parse_problem` for the text format, `ParseError` |
| `include/depresolve/resolver.hpp` | `Resolver`, `Resolution`, `resolve()` |
| `include/depresolve/output.hpp` | `format_resolution` |
| `cli/main.cpp` | the `depresolve` tool |
| `tests/` | GoogleTest unit tests |

## Build

```sh
./build.sh                      # Release build into ./build
ctest --test-dir build          # run the unit tests
```

or with plain CMake: `cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build`.
Options: `-DDEPRESOLVE_BUILD_CLI=OFF`, `-DDEPRESOLVE_BUILD_TESTS=OFF`.
Requires a C++20 compiler and CMake 3.20+; tests need GoogleTest.

## Command line

`depresolve` reads the whole problem from stdin and writes the result to
stdout (`./run.sh` is a wrapper that finds the built binary).

```
$ printf 'a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n' | ./run.sh
a 1.0.0
b 1.0.0
c 1.2.5
```

Input is zero or more registry lines `name X.Y.Z: dep range, dep range`
followed by one final `root: dep range, ...` line. Output is one
`name version` line per chosen package sorted by name, or `unsatisfiable`.
The exit status is 0 in both cases; malformed input prints a message to stderr
and exits with 2. See `problems/depresolve/SPEC.md` for the full grammar and
the search definition.

## How it works

`Resolver` precomputes each package's versions sorted newest first and turns
every requirement into a contiguous index range of candidates (binary search,
done once). The search then runs on an explicit stack: choice points hold the
package, its remaining candidates and the pending-requirement list they
continue with; pending requirements are a persistent linked list in an arena
shared between choice points; chosen versions are undone through a trail. A
search step is therefore O(1) plus the requirements it adds, and recursion
depth is not bounded by the call stack.

## Library example

```cpp
#include <iostream>
#include "depresolve/depresolve.hpp"  // or include the individual headers

int main() {
  using namespace depresolve;
  Problem p = parse_problem(
      "a 2.0.0: b ~1.0.0\n"
      "a 1.0.0:\n"
      "b 1.0.0:\nb 1.0.5:\nb 2.0.0:\n"
      "root: a *, b *\n");

  if (auto resolution = resolve(p)) {
    for (const ResolvedPackage& pkg : resolution->packages)
      std::cout << pkg.name << ' ' << pkg.version.to_string() << '\n';  // a 2.0.0, b 1.0.5
  } else {
    std::cout << "unsatisfiable\n";
  }
}
```

Registries can also be built programmatically:

```cpp
Registry reg;
PackageId a = reg.intern("a"), b = reg.intern("b");
reg.add_version(b, {1, 0, 0}, {});
reg.add_version(a, {1, 0, 0}, {{b, *Range::parse("^1.0.0")}});
std::vector<Requirement> root{{a, Range::any()}};
Resolver resolver(reg, root);
std::optional<Resolution> result = resolver.resolve();
```
