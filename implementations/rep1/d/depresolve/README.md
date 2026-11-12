# depresolve

A small, dependency-free D library and command-line tool that resolves package
dependencies deterministically. Given a registry of package versions (each with
semver-style requirements) and a root manifest, it picks one version for every
package that is needed — or reports `unsatisfiable`.

The search is fully specified, so every run (and every implementation) yields
the same answer:

* depth-first, in the order requirements are written;
* a package's version is fixed by the *first* requirement that reaches it;
* candidates are tried newest first;
* failure backtracks chronologically to the most recent choice with an untried
  candidate.

The implementation is iterative (no recursion-depth limits) and each search
step is O(1) plus the requirements it adds: names are interned, ranges are
pre-converted to index intervals over each package's newest-first version list,
pending requirements are a shared persistent list, and choices are undone via a
trail rather than by copying state.

## Build

Requires LDC and dub.

```sh
./build.sh          # dub build -b release --compiler=ldc2  → ./depresolve
dub test --compiler=ldc2   # run the unit tests
```

## Command-line usage

`depresolve` reads the whole input on stdin and writes the resolution on stdout
(`./run.sh` is a wrapper that can be called from any directory).

```
$ cat input.txt
a 1.0.0: c ^1.0.0
b 1.0.0: c ~1.2.0
c 1.1.0:
c 1.2.5:
c 1.3.0:
root: a *, b *
$ ./run.sh < input.txt
a 1.0.0
b 1.0.0
c 1.2.5
```

### Input format

Zero or more registry lines followed by one root line, each ending in `\n`:

```
registry_line = name " " version ":" [ " " requirement { ", " requirement } ] "\n"
root_line     = "root:" [ " " requirement { ", " requirement } ] "\n"
requirement   = name " " range
range         = "*" | X.Y.Z | "^"X.Y.Z | "~"X.Y.Z | comparator { " " comparator }
comparator    = ( "<" | "<=" | ">" | ">=" ) X.Y.Z
```

Ranges follow npm semantics: `^0.2.3` is `>=0.2.3 <0.3.0`, `^0.0.3` is exactly
`0.0.3`, `~1.2.3` is `>=1.2.3 <1.3.0`; comparators are ANDed. Versions compare
numerically (`1.10.0 > 1.9.0`).

### Output

One `name version` line per picked package, sorted by name in byte order, or the
single line `unsatisfiable`. The exit status is 0 in both cases; malformed input
is reported on stderr with exit status 2.

## Library usage

Add the package to your `dub.sdl` (`dependency "depresolve" path="…"`, use the
`library` configuration) and import `depresolve`.

```d
import std.stdio;
import depresolve;

void main()
{
    Registry registry;
    registry.add("a", "1.0.0", ["c", "^1.0.0"]);
    registry.add("b", "1.0.0", ["c", "~1.2.0"]);
    registry.add("c", "1.1.0");
    registry.add("c", "1.2.5");
    registry.add("c", "1.3.0");

    Dependency[] root = [
        Dependency("a", VersionRange.parse("*")),
        Dependency("b", VersionRange.parse("*")),
    ];

    auto result = resolve(registry, root);
    if (result.success)
        foreach (pick; result.picks)
            writeln(pick.name, " ", pick.version_);   // a 1.0.0 / b 1.0.0 / c 1.2.5
    else
        writeln("unsatisfiable");
}
```

Or parse the text format directly:

```d
auto problem = parseProblem("a 1.0.0:\nroot: a ^1.0.0\n");
write(formatResolution(resolve(problem.registry, problem.root)));
```

### Modules

| module | contents |
|---|---|
| `depresolve.semver` | `Version`, `VersionRange` (half-open `[lo, hi)`), `SyntaxException` |
| `depresolve.registry` | `Registry`, `PackageVersion`, `Dependency` |
| `depresolve.parser` | `parseProblem`, `parseRequirements`, `Problem` |
| `depresolve.resolver` | `resolve`, `Resolution`, `Pick` |
| `depresolve.output` | `formatResolution` |

## Tests

Unit tests live next to the code (`dub test --compiler=ldc2`). They cover
version/range semantics, parsing errors, the specification's examples, cycles,
a 3000-deep chain, and a randomized cross-check of the optimised search against
a literal recursive transcription of the specified algorithm.

## License

MIT
