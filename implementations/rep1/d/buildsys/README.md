# buildsys — Kiln

Kiln is an incremental build system written in D. It reads a *workspace* (build
files in the **Kiln Build Language**, KBL, plus ordinary source files),
evaluates the build files into a graph of build steps, and executes the
out-of-date steps on a **simulated** set of parallel workers against a virtual
file system. Nothing is run by a real shell: Kiln's sixteen built-in commands
(`write`, `copy`, `concat`, `upper`, `grep`, `preprocess`, ...) are implemented
by the engine, and every command has an integer cost that drives a fully
deterministic scheduling simulation. Change detection is content based
(FNV-1a/64 hashes recorded in `.kiln-state`), with early cutoff and discovered
(depfile) dependencies.

A *session* is a scripted sequence of builds and workspace mutations; Kiln
runs the whole session and writes a log of everything that happened together
with the final state of the workspace. The full language and session
definition is in `problems/buildsys/SPEC.md` of the surrounding repository.

## Layout

```
dub.sdl            package manifest (configurations: application, library)
build.sh, run.sh   build the tool / run it from any directory
app/main.d         the command-line tool (thin wrapper over the library)
source/kiln/       the library, one module per responsibility:
  package.d          `import kiln;` public API
  text, hash         byte-string helpers, FNV-1a hashing
  vfs                virtual file system, cached hashes, glob index
  glob               glob pattern compiler and matcher
  lexer, ast, parser KBL lexer (comments, logical lines, tokens), syntax trees, parser
  value, builtins    KBL values and total order, the 39 built-in functions
  eval               tree-walking interpreter (scopes, rules, includes, steps)
  step, commands     step records, the 16 commands (incl. `preprocess`)
  graph              dependency graph, validation, deterministic cycle search
  state              `.kiln-state` reader/writer and change detection
  scheduler          the worker simulation and `runBuild`
  session, fsio      session scripts and log, loading/writing real directories
```

## Building

Requires LDC (tested with 1.41.0) and dub (tested with 1.40.0). Only the D
standard library is used.

```sh
./build.sh          # dub build -b release --compiler=ldc2  ->  bin/kiln
dub test --compiler=ldc2
```

## Command-line usage

```
bin/kiln <input directory> <output directory>
./run.sh  <input directory> <output directory>      # same, from any directory
```

The input directory holds `session.txt` (the session script) and the initial
workspace, including `main.kiln`, the root build file. The program writes

```
<output>/log.txt           the session log
<output>/workspace/<path>  every file of the final workspace
```

and exits 0 even when builds in the session fail: a build error is reported in
the log. (Exit code 2 means a usage error, 1 an I/O failure.)

Example workspace (`src/a.txt` contains `abc`):

`main.kiln`:

```
step {
    out "out/upper.txt"
    in "src/a.txt"
    cmd upper()
}
default "out/upper.txt"
```

`session.txt`:

```
build
touch src/a.txt
build
edit src/a.txt
hello
---
build -j 4
```

`log.txt`:

```
step 1: build (default) -j 1
  run 0 2 w0 out/upper.txt upper()
  ok ran=1 hit=0 time=2
step 2: touch src/a.txt
  ok
step 3: build (default) -j 1
  hit 0 out/upper.txt
  ok ran=0 hit=1 time=0
step 4: edit src/a.txt
  ok size=6
step 5: build (default) -j 4
  run 0 2 w0 out/upper.txt upper()
  ok ran=1 hit=0 time=2
```

## Using the library

```d
import std.stdio : write, writeln;
import kiln;

void main()
{
    // An in-memory workspace.
    auto fs = new Vfs;
    fs.write("main.kiln", `
step {
    out "out/hello.txt"
    cmd write("hello\n")
}
default "out/hello.txt"
`);

    // One build on 2 simulated workers.
    BuildResult r = runBuild(fs, [], 2);
    writeln(r.ok, " ran=", r.ran, " time=", r.time);      // true ran=1 time=1
    foreach (ref e; r.events)
        writeln(e.kind, " ", e.target, " ", e.command);   // run out/hello.txt write("hello\n")
    write(fs.read("out/hello.txt"));                      // hello

    // A second build is a cache hit.
    assert(runBuild(fs, [], 2).hits == 1);

    // Or run a whole session script and get the text of log.txt.
    auto log = runSession(fs, parseSession("build\nclean\nbuild -j 3\n"));
    write(log);
}
```

Failures are reported through `BuildResult.error` (a `KilnError` with a `kind`
such as `E_CYCLE` and a `detail`); `runBuild` itself does not throw for build
errors. To use the library from another dub project, depend on this package
and select its `library` configuration:

```sdl
dependency "buildsys" path="../buildsys"
subConfiguration "buildsys" "library"
```

## Tests

`dub test --compiler=ldc2` runs the D `unittest` blocks: each module has unit
tests for its own behaviour (lexer, parser, glob, built-ins, commands, state
file, graph, scheduler, ...), and `source/kiln/examples_test.d` runs end-to-end
sessions that mirror the worked examples of the language definition.
