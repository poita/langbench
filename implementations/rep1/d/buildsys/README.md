# buildsys — Kiln, an incremental build system in D

Kiln reads a *workspace* — build files written in the **Kiln Build Language**
(KBL) plus ordinary source files — evaluates the build files into a graph of
build steps, and runs the steps that are out of date on a simulated pool of
parallel workers against an in-memory file system. Nothing ever runs a real
shell: the sixteen built-in commands (`write`, `copy`, `concat`, `upper`,
`lower`, `grep`, `replace`, `sort_lines`, `reverse_lines`, `dedup`, `number`,
`indent`, `wrap`, `count_lines`, `hash`, `preprocess`) are implemented in
process, and each has an integer cost that drives a fully deterministic
scheduling simulation. Change detection is purely content based (64-bit
FNV-1a hashes recorded in `.kiln-state`).

A *session* is a scripted sequence of builds and workspace edits. Kiln runs the
whole session and writes a log of everything that happened plus the final state
of the workspace. The language, file formats and scheduler are specified in
`problems/buildsys/SPEC.md`; the design notes are in `APPROACH.md`.

The project is written in D using only the standard library (Phobos).

## Layout

```
dub.sdl             package manifest (configurations: cli, library, unittest)
build.sh / run.sh   build the CLI / run it from any directory
source/app.d        the command-line tool (thin wrapper over the library)
source/kiln/        the library
tests/              unit tests (separate from the library sources)
```

Library modules, by responsibility:

| Module | Responsibility |
|--------|----------------|
| `kiln.errors` | `KilnError` (kind + detail) and error constructors |
| `kiln.hash`, `kiln.bytes`, `kiln.paths` | FNV-1a, byte-string helpers, workspace-path rules |
| `kiln.vfs` | in-memory file system with cached hashes and a sorted glob index |
| `kiln.lexer`, `kiln.ast`, `kiln.parser` | comment stripping, logical lines, tokens, AST |
| `kiln.value`, `kiln.glob`, `kiln.builtins` | values and their total order, glob matcher, the 39 functions |
| `kiln.interp` | scopes, statements, rules, `include`, step construction and validation |
| `kiln.commands`, `kiln.step` | the sixteen commands; steps and canonical command strings |
| `kiln.graph` | reference resolution, duplicate detection, cycle search, reachability |
| `kiln.state` | `.kiln-state` reader/writer and the freshness decision |
| `kiln.build` | one build: configuration, event-driven scheduler, execution |
| `kiln.session`, `kiln.fsio` | the session script driver and log; real-directory I/O |

## Building

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh                      # dub build -b release --compiler=ldc2  -> ./kiln
dub test --compiler=ldc2        # unit tests
```

## Command-line use

```
./run.sh <input directory> <output directory>
```

The input directory holds `session.txt`, usually a `main.kiln`, and the initial
workspace files. The output directory receives `log.txt` and
`workspace/<path>` for every file of the final workspace. A failing build is
normal output (an `error` line in the log), so the exit code is 0; it is
nonzero only for usage or I/O problems.

Example input:

```
session.txt:   build -j 2
               edit src/a.txt
               hello
               ---
               build -j 2
main.kiln:     step {
                   out "out/a.txt"
                   in "src/a.txt"
                   cmd upper()
               }
               default "out/a.txt"
src/a.txt:     hi
```

produces a `log.txt` like

```
step 1: build (default) -j 2
  run 0 2 w0 out/a.txt upper()
  ok ran=1 hit=0 time=2
step 2: edit src/a.txt
  ok size=6
step 3: build (default) -j 2
  run 0 2 w0 out/a.txt upper()
  ok ran=1 hit=0 time=2
```

and a `workspace/` with `main.kiln`, `src/a.txt`, `out/a.txt` and `.kiln-state`.

## Using the library

Add the package as a dependency (or use the `library` configuration) and
import the modules you need. This runs a build and a whole session in memory:

```d
import kiln.build : runBuild;
import kiln.session : runSession;
import kiln.vfs : Vfs;

void main()
{
    auto vfs = new Vfs;
    vfs.put("main.kiln", "step {\n out \"out/hi.txt\"\n cmd write(\"hi\\n\")\n}\n"
                       ~ "default \"out/hi.txt\"\n");
    vfs.put("src/unused.txt", "x\n");

    // One build with two simulated workers; no explicit targets = defaults.
    auto report = runBuild(vfs, [], 2);
    assert(report.ok && report.ran == 1);
    assert(vfs.content("out/hi.txt") == "hi\n");

    // A second build is a cache hit, found by content hash.
    assert(runBuild(vfs, [], 2).hits == 1);

    // Or drive a scripted session and get the log text back.
    string log = runSession(vfs, "build\nclean\nbuild\n");
}
```

Public entry points: `kiln.build.runBuild` (one build -> `BuildReport` with
the event list, counters and error), `kiln.session.runSession` (a script ->
`log.txt` text), `kiln.fsio.loadInput` / `writeOutput` (real directories),
`kiln.vfs.Vfs` (the workspace), and, lower down, `kiln.parser.parseSource`,
`kiln.interp.Interp`, `kiln.glob.GlobPattern` and
`kiln.state.parseState` / `renderState`.

## Tests

`dub test --compiler=ldc2` runs the unit tests in `tests/` (lexer, parser,
glob, evaluator and built-ins, commands, state file, end-to-end builds). The
conformance suite is run from the repository root with
`python3 run_tests.py buildsys -- buildsys/run.sh`.
