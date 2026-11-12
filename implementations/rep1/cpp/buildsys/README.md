# Kiln

Kiln is an incremental build system, written as a C++20 library with a thin
command-line front end. It reads a *workspace* — build files in the **Kiln Build
Language** (KBL) plus ordinary source files — evaluates the build files into a
graph of build steps, and runs the steps that are out of date on a simulated set
of parallel workers against an in-memory file system. Nothing is ever run by a
real shell: the sixteen built-in commands (`write`, `copy`, `concat`, `grep`,
`preprocess`, ...) are implemented by the engine, and each has an integer *cost*
that drives a fully deterministic scheduling simulation.

The behaviour (the language, the commands, the state file, the scheduler and
the log format) is specified in `problems/buildsys/SPEC.md`; the design notes are
in `problems/buildsys/APPROACH.md`.

## Building

Requirements: a C++20 compiler, CMake ≥ 3.20, and (for the tests) GoogleTest.

```sh
./build.sh                      # Release build into ./build
ctest --test-dir build          # run the unit tests
```

`build.sh` is equivalent to:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
```

CMake options: `KILN_BUILD_CLI` (default `ON`) and `KILN_BUILD_TESTS` (default
`ON`; skipped with a warning when GoogleTest is not found). Only the standard
library is used by the library and the tool.

## Command-line tool

```
kiln <input directory> <output directory>
./run.sh <input directory> <output directory>      # same thing, from any directory
```

The input directory holds `session.txt` (the script), usually `main.kiln` (the
root build file) and the initial workspace. The tool writes into the output
directory:

- `log.txt` — one block per session step: the events of every build (`run`,
  `hit`, `fail`, `cancel`), the result (`ok ran=.. hit=.. time=..` or
  `error E_...`), and so on;
- `workspace/…` — every file of the final workspace, including `out/…` and
  `.kiln-state`.

The exit code is 0 whenever the session ran, including sessions with build
errors (those are normal log output); it is nonzero only for usage or I/O
errors.

### Session scripts

```
# comment
build [TARGET ...] [-j N]     # build the targets (default list if none) on N workers
create PATH                   # followed by content lines, ended by a line `---`
edit PATH                     #   (same)
delete PATH
touch PATH                    # never causes a rebuild: change detection is by content
clean                         # delete out/… and .kiln-state
```

### A small example

`main.kiln`:

```
let names = ["alpha", "beta"]
each i, n in names {
    step {
        out "out/{n}.txt"
        cmd write("{i}:{n}\n")
    }
}
step {
    out "out/all.txt"
    in map(names, "out/%.txt")
    cmd concat()
}
default "out/all.txt"
```

`session.txt`:

```
build -j 2
build -j 2
```

`log.txt`:

```
step 1: build (default) -j 2
  run 0 1 w0 out/alpha.txt write("0:alpha\n")
  run 0 1 w1 out/beta.txt write("1:beta\n")
  run 1 3 w0 out/all.txt concat()
  ok ran=3 hit=0 time=3
step 2: build (default) -j 2
  hit 0 out/alpha.txt
  hit 0 out/beta.txt
  hit 0 out/all.txt
  ok ran=0 hit=3 time=0
```

## Using the library

Link against `kiln::kiln` (the static library target) and include
`<kiln/kiln.hpp>`, or just the module headers you need.

```cpp
#include <iostream>
#include "kiln/kiln.hpp"

int main() {
  kiln::Vfs ws;                                   // the virtual workspace
  ws.write("src/a.txt", "hello\n");
  ws.write("main.kiln", R"(
step {
    out "out/a.txt"
    in "src/a.txt"
    cmd upper()
}
default "out/a.txt"
)");

  kiln::BuildOptions options;                     // targets empty => default list
  options.workers = 2;

  kiln::BuildReport first = kiln::run_build(ws, options);
  std::cout << "ran=" << first.ran << " time=" << first.time << "\n";   // ran=1 time=2
  std::cout << *ws.read("out/a.txt");                                    // HELLO

  kiln::BuildReport second = kiln::run_build(ws, options);
  std::cout << "hits=" << second.hits << "\n";                           // hits=1

  ws.write("main.kiln", "abort \"nope\"\n");
  kiln::BuildReport bad = kiln::run_build(ws, options);
  if (!bad.ok()) std::cout << bad.error->text() << "\n";                 // E_ABORT nope

  // Whole scripted sessions are available too:
  kiln::Vfs ws2 = kiln::Vfs::load_directory("some/input", "session.txt");
  std::string log = kiln::run_session(ws2, "build -j 4\nclean\n");
}
```

### Modules

| Header | Responsibility |
|--------|----------------|
| `kiln/error.hpp` | the thirty error kinds and the `Error` exception |
| `kiln/hash.hpp`, `kiln/path.hpp` | FNV-1a-64; workspace path and name predicates |
| `kiln/vfs.hpp` | virtual file system: shared content, cached hashes, glob index, directory load/save |
| `kiln/glob.hpp` | glob pattern compiler and matcher |
| `kiln/value.hpp` | KBL values (`str`, `int`, `bool`, `list`), total order, equality |
| `kiln/lexer.hpp`, `kiln/ast.hpp`, `kiln/parser.hpp` | comment stripping, logical lines, tokens; syntax tree; block-aware parser |
| `kiln/builtins.hpp` | the 39 built-in functions |
| `kiln/evaluator.hpp`, `kiln/step.hpp` | tree-walking interpreter with scopes, rules, `include`; the resulting `BuildDescription` |
| `kiln/commands.hpp` | the sixteen commands, canonical command strings, `preprocess` |
| `kiln/graph.hpp` | duplicate/reference validation, target resolution, deterministic cycle search, reachability |
| `kiln/state.hpp` | `.kiln-state` reader/writer and change detection |
| `kiln/scheduler.hpp` | the deterministic event-driven worker simulation |
| `kiln/build.hpp` | one complete build (`run_build`) |
| `kiln/session.hpp` | session scripts and `log.txt` formatting |

### Design notes

- File content is immutable and shared, and each file caches its hash, so a
  distinct content is hashed once and reading is O(1). KBL values share their
  string and list storage, so copying is O(1) and `a ++ b` is O(|a| + |b|).
- `glob` binary-searches a sorted index of eligible paths by the pattern's
  wildcard-free prefix instead of scanning the workspace.
- The scheduler keeps its ready steps in min-heaps keyed by serial number, so a
  ready-set operation is O(log R).
- Every build evaluates from scratch; only the workspace (including
  `.kiln-state`) carries over between builds.

## Tests

`tests/` holds GoogleTest suites for each layer (hashing and paths, the VFS,
globbing, lexer and parser error selection, expressions and built-ins,
statements and rules, steps, commands, the state file, and end-to-end sessions
including all of the specification's worked examples). Run them with
`ctest --test-dir build` or `build/tests/kiln_tests`.

The conformance suite lives outside the project:

```sh
python3 run_tests.py buildsys -- buildsys/run.sh
```
