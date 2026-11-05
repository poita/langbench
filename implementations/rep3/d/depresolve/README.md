# depresolve

A package dependency resolver written in D. Given a registry (every version of
every package with its requirements) and a root manifest, it picks exactly one
version for every needed package. The search is fully specified — depth-first,
newest version first, chronological backtracking — so the first solution found
is deterministic. When none exists it reports `unsatisfiable`.

The implementation follows a flat, allocation-light design: package names are
interned to integer ids, versions are packed into one order-preserving
integer, every range becomes a half-open key interval resolved once to a
window of candidate indices, and the search runs iteratively with an explicit
frame stack and a persistent pending list in an arena (no recursion, no
copying of state per step). Only the D standard library is used.

## Layout

```
dub.sdl                  project manifest (configurations: cli, library, unittest)
source/depresolve/       the library
  semver.d               packed Version key
  range.d                ranges (*, exact, ^, ~, comparators) as key intervals
  registry.d             parsing into flat arrays; per-requirement candidate windows
  resolver.d             the iterative backtracking search
  output.d               output formatting
  package.d              public import + resolveText convenience
cli/main.d               thin command-line tool
tests/                   unit tests (separate from the library source)
build.sh, run.sh         build and run helpers
```

## Build

Requires LDC and dub.

```
./build.sh          # dub build -b release --compiler=ldc2 ; produces ./depresolve
dub test --compiler=ldc2
```

## Command line

`depresolve` reads the whole input on stdin and writes the result to stdout
(`./run.sh < input`). It takes no arguments and exits 0 in both outcomes.

Input is registry lines followed by one root line:

```
a 1.0.0: c ^1.0.0
b 1.0.0: c ~1.2.0
c 1.1.0:
c 1.2.5:
c 1.3.0:
root: a *, b *
```

Ranges: `*`, `X.Y.Z` (exact), `^X.Y.Z`, `~X.Y.Z` (npm semantics), or one to
three space-separated comparators (`<`, `<=`, `>`, `>=`) that must all hold.

Output is one `name version` line per chosen package, sorted by name in byte
order, or the single line `unsatisfiable`:

```
a 1.0.0
b 1.0.0
c 1.2.5
```

## Library example

Add the package as a dependency using the `library` configuration:

```sdl
dependency "depresolve" path="../depresolve"
subConfiguration "depresolve" "library"
```

```d
import std.stdio : write, writeln;
import depresolve;

void main()
{
    enum input = "a 1.0.0: c ^1.0.0\n"
               ~ "b 1.0.0: c ~1.2.0\n"
               ~ "c 1.1.0:\nc 1.2.5:\nc 1.3.0:\n"
               ~ "root: a *, b *\n";

    // One call: text in, formatted text out.
    write(resolveText(input));

    // Or step by step:
    auto registry = Registry.parse(input);   // throws ParseException on bad input
    auto result = resolve(registry);
    if (result.satisfiable)
        foreach (pick; result.picks)
            writeln(pick.name, " ", pick.version_);
}
```

## Tests

`dub test --compiler=ldc2` runs the unit tests in `tests/` (versions, ranges,
registry parsing and windows, and the resolver including the examples from the
specification, cycles, deep chains and exhaustive failure).
