# depresolve

A deterministic package dependency resolver written in D. Given a registry
(every version of every package with its requirements) and a root manifest, it
picks one version per needed package using a fully specified search: depth
first, newest version first, chronological backtracking. It prints the first
solution that search finds, or `unsatisfiable`.

It ships as a library (`depresolve`) and a thin command-line tool on top of it.
Only the D standard library (plus `core.stdc.stdlib`) is used.

## Build

Requires LDC 1.41.0 and dub 1.40.0.

```sh
./build.sh          # = dub build -b release --compiler=ldc2 --config=cli
dub test --compiler=ldc2   # unit tests
```

The executable is written to `bin/depresolve`.

## Command-line usage

`depresolve` reads the whole input on stdin and writes the result on stdout
(`./run.sh` runs it from any directory). It takes no arguments and always exits 0.

Input: registry lines `name MAJOR.MINOR.PATCH: req, req, ...`, then one last line
`root: req, req, ...`. A requirement is `name range`, where the range is `*`, an
exact version, `^X.Y.Z`, `~X.Y.Z`, or one to three comparators
(`<`, `<=`, `>`, `>=`) separated by spaces, all of which must hold.

```
$ printf 'a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n' | ./run.sh
a 1.0.0
b 1.0.0
c 1.2.5
```

Output is one `name version` line per chosen package sorted by name in byte
order, or the single line `unsatisfiable`. An empty root prints nothing.

## Library

```d
import depresolve;

void main()
{
    auto res = resolveText("a 1.0.0: b ^1.0.0\nb 1.2.0:\nb 1.1.0:\nroot: a *\n");
    assert(res.satisfiable);
    foreach (c; res.choices)               // sorted by name
        writeln(c.name, " ", c.versionString);   // a 1.0.0 / b 1.2.0
}
```

For finer control, build the pieces yourself:

```d
auto reg = parseRegistry(text);   // intern names, pack versions, resolve ranges to windows
auto res = resolve(reg);          // the iterative search
string out_ = formatResolution(res);
```

To use it as a dependency, add `dependency "depresolve" path="..."` and the
`library` configuration (`subConfiguration "depresolve" "library"`).

### Modules

| module | responsibility |
|---|---|
| `depresolve.semver` | versions packed into one `ulong` key (21 bits per component) |
| `depresolve.range` | `*`, exact, `^`, `~` and comparator ranges as one `[lo, hi)` interval |
| `depresolve.registry` | parsing, name interning, per-package newest-first version lists, requirement candidate windows |
| `depresolve.resolver` | the iterative search, `Resolution`, output formatting |

## Design

Names are interned to dense ids; each requirement is stored once as
`(package, interval)` and, after parsing, resolved by binary search to a window
of candidate indices in the package's newest-first version list. The search uses
an explicit frame stack, a `chosen` array indexed by package id, and a pending
list held as a persistent linked list in an arena that is truncated on
backtrack, so nothing is copied per step and recursion depth is unbounded.

## Layout

```
dub.sdl           manifest (configurations: cli, library, unittest)
source/depresolve library
app/main.d        CLI
tests/            unit tests (separate from the library source)
build.sh run.sh   build and run scripts
```
