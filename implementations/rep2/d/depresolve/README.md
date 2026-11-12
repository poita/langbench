# depresolve

A package dependency resolver written in D. Given a registry (every version of
every package, with its requirements) and a root manifest, it picks one version
per needed package using a fixed search — depth-first, newest version first,
chronological backtracking — so the printed resolution is deterministic and
reproducible by any conforming implementation. If no resolution exists it
prints `unsatisfiable`.

It consists of a reusable library (`source/depresolve/`) and a thin CLI
(`source/app.d`).

## Build

Requires LDC 1.41.0 and dub 1.40.0; only the D standard library is used.

```sh
./build.sh          # same as: dub build -b release --compiler=ldc2
dub test --compiler=ldc2
```

This produces the `./depresolve` executable. `./run.sh` runs it from any
directory.

## CLI

Reads the whole input from stdin and writes the result to stdout (no
arguments, no files). Exit status is 0 whether or not a resolution exists.

Input: registry lines `name MAJOR.MINOR.PATCH: req, req, ...` followed by one
root line `root: req, ...`. A requirement is `name range`, where range is one of
`*`, `1.2.3` (exact), `^1.2.3`, `~1.2.3`, or one to three space-separated
comparators (`<`, `<=`, `>`, `>=` followed by a version); caret and tilde follow
npm semantics.

```console
$ printf 'a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n' | ./run.sh
a 1.0.0
b 1.0.0
c 1.2.5
```

Output is one `name version` line per chosen package, sorted by name in byte
order, or the single line `unsatisfiable`.

## Library

| module | purpose |
|---|---|
| `depresolve.semver` | `Version` (numeric ordering), `ParseException` |
| `depresolve.range` | `VersionRange`, a half-open `[lo, hi)` interval; `parseRange`, `caret`, `tilde`, ... |
| `depresolve.registry` | `Registry`, `Requirement`; sorts versions newest first and binds each requirement to its candidate index range by binary search |
| `depresolve.parser` | `parseProblem` for the text format |
| `depresolve.resolver` | `resolve` — the iterative search with a shared pending list and a trail (no recursion, no copying at choice points) |
| `depresolve.format` | `formatResolution` |

`import depresolve;` re-exports everything. Use it as a dub dependency with
`subConfiguration "depresolve" "library"`.

```d
import depresolve;
import std.stdio;

void main()
{
    // From text...
    auto problem = parseProblem("a 1.0.0: b ^1.0.0\nb 1.2.0:\nroot: a *\n");
    write(formatResolution(resolve(problem)));       // a 1.0.0 / b 1.2.0

    // ...or built programmatically.
    Registry reg;
    reg.add("app", "1.0.0", "lib ^1.0.0");
    reg.add("lib", "1.4.0");
    reg.add("lib", "2.0.0");
    auto result = resolve(reg, [Requirement(reg.intern("app"), parseRange("*"))]);
    foreach (p; result.picks)
        writeln(p.name, " ", p.version_);
}
```

## Tests

Unit tests are D `unittest` blocks in each module (including the worked
examples from the specification, deep chains and backtracking cases), run with
`dub test --compiler=ldc2`.
