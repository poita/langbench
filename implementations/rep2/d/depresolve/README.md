# depresolve

A deterministic package dependency resolver written in D. Given a registry
(every version of every package with its requirements) and a root manifest, it
picks one version for every package that is needed, so that all requirements
are met. It returns the **first** solution of a fixed search — depth-first,
newest version first, chronological backtracking — so every correct
implementation prints the same answer. If none exists it prints
`unsatisfiable`.

The library is a flat, allocation-light implementation: package names are
interned to dense ids, versions are packed into one 64-bit integer key, every
range becomes a half-open key interval resolved once into a window of candidate
indices, and the search is iterative (explicit frame stack, persistent pending
list in a truncatable arena, undo through the frames). There is no recursion,
so 10,000+-deep chains are fine.

Only the D standard library is used.

## Build

Requires LDC (tested with 1.41.0) and dub (1.40.0).

```sh
./build.sh        # dub build -b release --compiler=ldc2  ->  bin/depresolve
dub test --compiler=ldc2   # unit tests (tests/)
```

## Command-line use

`./run.sh` (or `bin/depresolve`) reads the whole input on stdin and writes the
resolution on stdout. Exit status is 0 for both a solution and
`unsatisfiable`; malformed input prints a message to stderr and exits 2.

Input: registry lines `name MAJOR.MINOR.PATCH: req, req, ...` followed by a
final `root: req, ...` line. A requirement is `name range`, where range is
`*`, an exact version, `^X.Y.Z`, `~X.Y.Z`, or one to three space-separated
comparators (`<`, `<=`, `>`, `>=`) that must all hold. Caret and tilde follow
npm semantics.

```console
$ printf 'a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n' | ./run.sh
a 1.0.0
b 1.0.0
c 1.2.5
```

Output is one `name version` line per chosen package, sorted by name in byte
order, or the single line `unsatisfiable`.

## Library use

The `library` dub configuration builds only the library:

```sdl
dependency "depresolve" path="../depresolve"
subConfiguration "depresolve" "library"
```

From text:

```d
import depresolve;

void main()
{
    auto reg = parseInput("a 1.0.0: b ^1.0.0\nb 1.2.0:\nb 1.3.0:\nroot: a *\n");
    auto res = resolve(reg);
    assert(res.satisfiable);
    foreach (p; res.picks)           // sorted by name
        writeln(p.name, " ", p.version_);
    // a 1.0.0
    // b 1.3.0
}
```

Or programmatically:

```d
RegistryBuilder b;
b.addVersion("lib", Version(1, 0, 0));
b.addVersion("lib", Version(1, 1, 0));
b.addVersion("app", Version(0, 1, 0), [RequirementSpec("lib", parseRange("^1.0.0"))]);
b.setRoot([RequirementSpec("app", anyVersion)]);
auto res = resolve(b.build());      // app 0.1.0, lib 1.1.0
```

`solve(string input)` does parse + resolve + format in one call.

### Modules

| module | responsibility |
|---|---|
| `depresolve.semver` | `Version`, packed `VersionKey`, `parseVersion`, `ParseException` |
| `depresolve.range` | `Interval`, `parseRange` (`*`, exact, `^`, `~`, comparators) |
| `depresolve.registry` | `Registry`, `RegistryBuilder`: interned ids, sorted versions, candidate windows |
| `depresolve.parser` | `parseInput`: the textual registry/root format |
| `depresolve.resolver` | `resolve` (the search), `Resolution`, `formatResolution` |
| `depresolve` | public import of all of the above, plus `solve` |

## Layout

```
source/depresolve/   library
cli/app.d            command-line tool
tests/               unit tests (separate modules, run by `dub test`)
build.sh run.sh      build and run scripts
```
