# Kiln

Kiln is an incremental build system simulator written in D. It reads a
*workspace* of build files (written in the **Kiln Build Language**, KBL) and
source files, evaluates the build files into a graph of steps, and executes
the out-of-date steps on a deterministic simulation of parallel workers
against an in-memory virtual file system. Nothing runs a real shell: the
sixteen built-in commands (`write`, `copy`, `concat`, `grep`, `preprocess`, …)
are implemented by the engine, and each has an integer cost that drives the
scheduler. Change detection is content based (64-bit FNV-1a hashes recorded in
a `.kiln-state` file), including discovered dependencies from depfiles and
early cutoff when a rebuilt file comes out byte-identical.

A *session* — a script of builds and workspace edits — is run end to end and
produces a log plus the final workspace. The language, file formats, error
messages and scheduler are specified in `problems/buildsys/SPEC.md`.

## Requirements

* LDC 1.41.0 (`ldc2`) and dub 1.40.0
* the D standard library only; there are no other dependencies

## Build

```sh
./build.sh          # runs: dub build -b release --compiler=ldc2
```

This produces `bin/kiln`. `build.sh` and `run.sh` work from any directory.

## Test

```sh
dub test --compiler=ldc2
```

The unit tests live in `tests/`, separate from the library in `source/kiln/`.
The end-to-end suite is run from the repository root:

```sh
buildsys/build.sh && python3 run_tests.py buildsys -- buildsys/run.sh
```

## Command line

```
kiln <input directory> <output directory>
# or: ./run.sh <input directory> <output directory>
```

The input directory contains `session.txt` (the session script), usually a
`main.kiln` root build file, and any other files, which form the initial
workspace. Kiln writes into the output directory:

* `log.txt` — one block per session step: `build` (with `hit`/`run`/`fail`/
  `cancel` events and an `ok` or `error` line), `create`, `edit`, `delete`,
  `touch` and `clean`;
* `workspace/…` — every file of the final workspace, including generated
  `out/…` files and `.kiln-state`.

Build errors are normal output (an `error E_…` line in the log); the exit
status is 0 unless the command line is misused (status 2).

### Session script

```
# comments and blank lines are skipped
build @all out/app.txt -j 4     # targets are optional; -j N sets the workers
edit src/a.txt                  # create/edit take content up to a line "---"
new text
---
delete src/old.txt
touch src/a.txt                 # never causes a rebuild: content is what counts
clean                           # removes out/… and .kiln-state
```

### A small build file

```
let names = ["alpha", "beta"]
each i, n in names {
    step {
        out "out/{n}.txt"
        cmd write("{i}:{n}\n")
    }
}
step {
    out "out/index.txt"
    in map(names, "out/%.txt")
    cmd concat()
}
default "out/index.txt"
```

## Library

The code is a reusable library (`import kiln;`) plus a thin CLI (`source/app.d`).
Modules, by responsibility:

| Module | Role |
|--------|------|
| `kiln.vfs`, `kiln.hash`, `kiln.paths`, `kiln.bytes` | virtual file system with cached content hashes and a sorted glob index; FNV-1a; workspace path rules; byte-string helpers |
| `kiln.lexer`, `kiln.parser`, `kiln.ast` | comment stripping, logical lines, tokens; statement and expression parser (string interpolation is parsed once) |
| `kiln.value`, `kiln.builtins`, `kiln.glob` | KBL values and their total order; the 39 built-in functions; glob compiler and allocation-free matcher |
| `kiln.interp`, `kiln.plan` | scoped tree-walking evaluator producing a `Plan` of steps and phony targets |
| `kiln.graph` | whole-graph validation, target resolution, deterministic cycle detection, reachable set |
| `kiln.commands`, `kiln.state` | the sixteen commands; the strict state-file reader/writer and freshness test |
| `kiln.build`, `kiln.heap` | one build: event-driven scheduler simulation (two min-heaps keyed by step serial) |
| `kiln.session`, `kiln.fsio` | session scripts and `log.txt`; loading and writing real directories |

### Example

```d
import std.stdio;
import kiln;

void main()
{
    auto ws = new Vfs;
    ws.write("main.kiln",
        "step {\n    out \"out/hello.txt\"\n    cmd write(\"hello\\n\")\n}\n" ~
        "default \"out/hello.txt\"\n");

    auto first = runBuild(ws, null, 2);   // no targets = the default targets, 2 workers
    writeln(first.ran, " ran, ", first.hits, " hits, time ", first.time);   // 1 ran, 0 hits, time 1

    auto second = runBuild(ws, null, 2);
    writeln(second.ran, " ran, ", second.hits, " hits");                    // 0 ran, 1 hits
    writeln(cast(string) ws.read("out/hello.txt"));                         // hello

    // Or run a whole session script and get the text of log.txt:
    write(runSession(ws, "touch main.kiln\nbuild -j 4\n"));
}
```

A configuration error does not throw out of `runBuild`: it is returned in
`BuildReport.error` (a `KilnError` whose `render()` is e.g.
`E_UNKNOWN_VAR greeting`). To use the library from another dub project, depend
on this package and select its `library` configuration.

## Layout

```
dub.sdl             package manifest (configurations: cli, library, unittest)
build.sh run.sh     build and run scripts
source/app.d        the command-line tool
source/kiln/        the library
tests/              unit tests (run by `dub test`)
```
