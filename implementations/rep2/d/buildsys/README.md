# buildsys — Kiln, an incremental build system

Kiln reads a *workspace* (build files in the **Kiln Build Language**, KBL, plus
ordinary source files), evaluates the build files into a graph of build steps,
and runs the out-of-date steps on a simulated pool of parallel workers against
an in-memory virtual file system. Nothing is ever executed by a real shell: the
sixteen built-in commands (`write`, `copy`, `concat`, `upper`, `grep`,
`preprocess`, …) are implemented by the engine, and each has an integer cost
that drives a fully deterministic scheduling simulation. Change detection is
content based (64-bit FNV-1a) and persisted in `.kiln-state`.

This project is a library (`kiln`) plus a thin command-line tool (`buildsys`)
that replays a scripted session of builds and workspace edits and writes a log.
The language, file formats, error messages and scheduler are defined by the
problem's `SPEC.md`; `APPROACH.md` describes the design followed here.

It uses only the D standard library.

## Building

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh          # dub build -b release --compiler=ldc2 ; produces ./buildsys
dub test --compiler=ldc2   # unit tests (tests/)
```

## Command-line use

```
buildsys <input directory> <output directory>
# or
./run.sh <input directory> <output directory>
```

`<input directory>` holds `session.txt` (the session script) and the initial
workspace (`main.kiln`, sources, optionally `out/` and `.kiln-state`). The tool
writes `<output>/log.txt` and a copy of the final workspace under
`<output>/workspace/`. It exits 0 even when a build fails: build errors are
normal output and appear in the log as `error <KIND> <detail>`.

A session script is a list of steps:

```
build [TARGET ...] [-j N]    # run a build; targets are paths or @phony names
create PATH                  # replace/create a file; content lines follow, ended by ---
edit PATH                    #   (identical to create)
delete PATH
touch PATH                   # never causes a rebuild
clean                        # remove out/ and .kiln-state
# comment lines and blank lines are ignored
```

Example `main.kiln`:

```
rule bundle(name, parts, weight = 2) {
    step {
        out "out/{name}.txt"
        in parts
        cmd concat()
        cost weight
    }
}
let base = glob("src/*.txt")
use bundle("all", base)
default "out/all.txt"
```

and `session.txt`:

```
build -j 2
edit src/a.txt
new contents
---
build -j 2
```

## Library use

The `kiln` package exposes the virtual file system, a single-build entry point
and the session driver:

```d
import kiln;
import std.stdio : writeln;

void main()
{
    auto ws = new Vfs;
    ws.write("src/a.txt", "hello\n");
    ws.write("main.kiln", `
        step {
            out "out/a.up"
            in "src/a.txt"
            cmd upper()
        }
        default "out/a.up"
    `);

    auto first = runBuild(ws, null, 2);        // targets = defaults, 2 workers
    writeln(first.ok, " ran=", first.ran);     // true ran=1
    writeln(ws.read("out/a.up"));              // HELLO

    auto second = runBuild(ws);                // nothing changed: a cache hit
    writeln(second.hits);                      // 1

    // Replay a whole session script and get the log text.
    writeln(runSession(ws, parseSession("build\nclean\nbuild -j 4\n")));
}
```

Errors never escape `runBuild`: a failed build returns a `BuildReport` whose
`error` is a `KilnError` (`kind`, `detail`).

## Layout

| Path | Contents |
|------|----------|
| `source/kiln/package.d` | public import of the API |
| `source/kiln/errors.d` | `KilnError` and error constructors |
| `source/kiln/hash.d`, `paths.d`, `text.d` | FNV-1a, workspace-path predicates, byte-string helpers |
| `source/kiln/vfs.d` | virtual file system with cached hashes and a sorted glob index |
| `source/kiln/glob.d` | glob compilation and allocation-free matching |
| `source/kiln/lexer.d`, `ast.d`, `parser.d` | KBL lexing, AST, parsing (incl. string interpolation) |
| `source/kiln/value.d`, `builtins.d`, `interp.d` | values, the 39 built-in functions, the evaluator |
| `source/kiln/step.d`, `commands.d` | step model and the sixteen commands |
| `source/kiln/graph.d` | graph validation, target resolution, cycle detection |
| `source/kiln/state.d` | `.kiln-state` reader/writer and freshness check |
| `source/kiln/scheduler.d`, `build.d` | scheduling simulation and the per-build driver |
| `source/kiln/session.d` | session script parsing, replay and log rendering |
| `app/main.d` | the command-line tool |
| `tests/` | unit tests (separate from the library source) |
