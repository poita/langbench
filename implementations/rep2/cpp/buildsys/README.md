# Kiln

Kiln is an incremental build system with a deterministic scheduling simulation.
It reads a *workspace* — build files written in the **Kiln Build Language**
(KBL) plus ordinary source files — evaluates the build files into a graph of
steps, and runs the out-of-date steps on a simulated pool of parallel workers
against an in-memory virtual file system. Nothing is ever executed by a real
shell: Kiln's sixteen built-in commands are implemented by the engine, and each
has an integer *cost* that drives the simulation, so every run is fully
reproducible.

The behaviour is specified in `problems/buildsys/SPEC.md`; this project is a
C++17 implementation of it, split into a reusable library and a thin
command-line tool.

## Building

Requirements: a C++17 compiler and CMake ≥ 3.20. GoogleTest is optional and is
only used for the unit tests.

```sh
./build.sh                 # Release build into ./build
```

or, by hand:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build     # run the unit tests (needs GoogleTest)
```

Set `-DKILN_BUILD_TESTS=OFF` to skip the tests.

## Command line

```
kiln <input directory> <output directory>      # or: ./run.sh <input> <output>
```

The input directory holds `session.txt` (the script of builds and workspace
mutations), usually a `main.kiln` build file, and any other workspace files.
Kiln runs the session and writes into the output directory:

- `log.txt` — what happened, one block per session step;
- `workspace/…` — the final state of the virtual workspace (including
  generated `out/…` files and `.kiln-state`).

The exit status is `0` even when a build fails: build errors are reported in the
log, not through the exit code. A session script looks like

```
build @all -j 4            # build with 4 workers
edit src/a.txt             # replace a file's content ...
new content
---                        # ... up to the '---' line
build @all -j 4            # only what changed re-runs
clean
```

and a build file like

```
let names = ["alpha", "beta"]
each n in names {
    step {
        out "out/{n}.txt"
        cmd write("{n}\n")
    }
}
step {
    out "out/all.txt"
    in map(names, "out/%.txt")
    cmd concat()
}
default "out/all.txt"
```

## Library

Everything lives in namespace `kiln`; `#include <kiln/kiln.hpp>` pulls in the
whole public API. The modules, each with a header under `include/kiln/`:

| Module | Header | Responsibility |
|--------|--------|----------------|
| hashing | `hash.hpp` | 64-bit FNV-1a, hex rendering |
| paths | `path.hpp` | workspace path / phony name validation |
| errors | `error.hpp` | `Error` (kind + detail), as printed in the log |
| values | `value.hpp` | KBL values (`str`, `int`, `bool`, `list`), total order, equality |
| glob | `glob.hpp` | glob pattern compiler and matcher |
| file system | `vfs.hpp` | virtual file system with cached hashes and a sorted glob index |
| lexer | `lexer.hpp` | comment stripping, logical lines, tokens |
| parser | `ast.hpp`, `parser.hpp` | syntax trees, statement/expression parser |
| built-ins | `builtins.hpp` | the 39 KBL functions |
| interpreter | `interp.hpp`, `plan.hpp` | scopes, rules, `include`, steps → `BuildPlan` |
| commands | `commands.hpp` | the 16 commands, canonical command strings |
| graph | `graph.hpp` | steps/phonies/sources, validation, cycle detection |
| state | `state.hpp` | `.kiln-state` reader/writer and change detection |
| engine | `engine.hpp` | one complete build and its event-driven scheduler |
| session | `session.hpp` | session scripts and the log |

### Example

```cpp
#include <iostream>
#include <kiln/kiln.hpp>

int main() {
  kiln::Vfs vfs;
  vfs.write("src/a.txt", "abc\n");
  vfs.write("main.kiln", R"(
step {
    out "out/mid.txt"
    in "src/a.txt"
    cmd upper()
}
step {
    out "out/final.txt"
    in "out/mid.txt"
    cmd number()
}
default "out/final.txt"
)");

  // A scripted session: build, edit a source, build again.
  std::cout << kiln::runSession(vfs, "build -j 2\nedit src/a.txt\nABC\n---\nbuild -j 2\n");

  // Or drive a single build and inspect the report.
  kiln::BuildReport report = kiln::runBuild(vfs, {"out/final.txt"}, /*jobs=*/2);
  if (report.error) std::cout << "error " << report.error->message() << "\n";
  else std::cout << "ran=" << report.ran << " hit=" << report.hits << " time=" << report.time << "\n";

  std::cout << *vfs.read("out/final.txt");
}
```

Lower-level pieces can be used on their own: `kiln::parseBuildFile` gives a
syntax tree (throwing `kiln::Error` with kind `E_PARSE`), `kiln::Evaluator`
turns a workspace into a `BuildPlan`, `kiln::Graph::build` validates it, and
`kiln::GlobPattern` is a standalone glob matcher.

## Design notes

- **One hash per content.** The `Vfs` caches each file's FNV-1a hash until the
  file's content changes; freshness checks and state lines reuse it.
- **Evaluation is afresh every build.** Nothing but the file system (and its
  hashes) survives between builds.
- **`glob` is not a scan.** The `Vfs` keeps a sorted index of glob-eligible paths
  and a pattern only visits the range sharing its literal prefix.
- **O(1) copies.** KBL strings and lists are reference counted.
- **Scheduler.** Ready steps live in min-heaps keyed by serial number, so every
  ready-set operation is O(log R); the clock jumps from one completion to the
  next. Commands read their inputs at their start time and apply their writes at
  their end time.

## Layout

```
include/kiln/   public headers          src/     library implementation
cli/main.cpp    the `kiln` tool         tests/   GoogleTest unit tests
build.sh        configure + build       run.sh   run the CLI from anywhere
```
