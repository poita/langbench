# Kiln

Kiln is an incremental build system written in D. It reads a *workspace* — build
files in the **Kiln Build Language** (KBL) plus ordinary source files — evaluates
the build files into a graph of steps, decides which steps are out of date from
content hashes, and executes those on a deterministic simulation of parallel
workers against a virtual file system. Nothing is run in a real shell: Kiln's
sixteen built-in commands (`write`, `copy`, `concat`, `grep`, `preprocess`, …)
are implemented by the engine, and every command has an integer *cost* that
drives the scheduling simulation.

The project is a reusable library (`kiln.*`) and a thin command-line tool
(`kiln`) that runs a whole *session* — a script of builds and workspace edits —
and writes a log plus the final workspace.

## Requirements

* LDC 1.41.0 (`ldc2`) and dub 1.40.0
* No dependencies beyond the D standard library; tests use D's built-in `unittest`.

## Build

```sh
dub build -b release --compiler=ldc2     # produces ./kiln
# or, from any directory:
./build.sh
```

`dub build` builds the `application` configuration (the CLI). The `library`
configuration builds just the engine as a static library:
`dub build --config=library --compiler=ldc2`.

## Test

```sh
dub test --compiler=ldc2
```

This runs the unit tests embedded in every module plus the end-to-end session
tests in `tests/sessions.d` (the worked examples of the specification).

## Command-line use

```
kiln <input directory> <output directory>
./run.sh <input directory> <output directory>      # same, locates the binary itself
```

The input directory holds:

```
session.txt    the session script (required)
main.kiln      the root build file
...            the rest of the initial workspace (sources, included build files, .kiln-state)
```

The tool writes `log.txt` (the session log) and `workspace/` (every file of the
final workspace) into the output directory, and exits 0 even when builds fail —
a build error is normal output and appears in the log.

### session.txt

```
build [TARGET ...] [-j N]     run a build (targets are paths or @phony names)
create PATH                   write a file; content lines follow, ended by a line "---"
edit PATH                     same as create
delete PATH
touch PATH                    updates a modification stamp; never causes a rebuild
clean                         remove out/... and .kiln-state
```

Blank lines and `#` comments between steps are ignored.

### Example

`main.kiln`:

```
step {
    out "out/hello.txt"
    cmd write("hello\n")
}
default "out/hello.txt"
```

`session.txt`:

```
build
build
```

`log.txt`:

```
step 1: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
step 2: build (default) -j 1
  hit 0 out/hello.txt
  ok ran=0 hit=1 time=0
```

## Library use

```d
import kiln;
import std.stdio : writeln;

void main()
{
    auto ws = new Workspace;
    ws.write("src/a.txt", "alpha\n");
    ws.write("main.kiln", `
        step {
            out "out/upper.txt"
            in "src/a.txt"
            cmd upper()
        }
        default "out/upper.txt"
    `);

    auto first = runBuild(ws, [], 2);          // targets = default list, two workers
    writeln(first.ok, " ran=", first.ran);     // true ran=1
    writeln(ws.read("out/upper.txt"));         // ALPHA

    auto second = runBuild(ws, [], 2);         // content unchanged: a cache hit
    writeln("hits=", second.hits);             // hits=1

    // Whole sessions can be driven from text, producing the log text:
    writeln(runSession(ws, "edit src/a.txt\nbeta\n---\nbuild\n"));
}
```

### Modules

| Module | Responsibility |
|--------|----------------|
| `kiln.workspace` | virtual file system, workspace-path rules, cached hashes, sorted glob index, loading/writing real directories |
| `kiln.hash`, `kiln.bytes` | FNV-1a 64, byte-string helpers (never decode UTF-8) |
| `kiln.lexer` | comment stripping, logical lines, tokens (one shared literal scanner) |
| `kiln.parser`, `kiln.ast` | statement/expression trees, block structure, `E_PARSE` precedence |
| `kiln.value`, `kiln.glob`, `kiln.builtins` | KBL values and total order, glob matcher, the 39 built-in functions |
| `kiln.eval` | tree-walking interpreter: scopes, rules, `include`, `step` validation |
| `kiln.model`, `kiln.commands` | steps and phony targets; the 16 commands and `preprocess` |
| `kiln.graph` | graph construction, reference resolution, cycle detection, reachability |
| `kiln.state` | strict `.kiln-state` reader/writer and the freshness decision |
| `kiln.scheduler` | event-driven worker simulation with O(log R) ready queues |
| `kiln.build` | one complete build (`runBuild`) |
| `kiln.session` | session scripts (`parseSession`, `runSession`) and the log |
| `kiln` | umbrella module re-exporting the public API |

## Design notes

* Strings are byte strings; the code never decodes UTF-8, so binary content is safe.
* Each file content is hashed once (the hash is cached on the file entry); `hash()`, freshness checks and
  state lines share it.
* Every build evaluates afresh; only the file system, its hashes and the glob index persist.
* `glob` binary-searches a sorted index by the pattern's wildcard-free prefix.
* Copying a string or list is O(1) (shared slices); `a ++ b` allocates.
* Ready steps live in binary min-heaps keyed by serial number.
