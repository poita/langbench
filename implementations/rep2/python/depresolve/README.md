# depresolve

A small, dependency-free Python library and CLI that resolves package
dependencies. Given a registry (every version of every package with its
requirements) and a root manifest, it picks one version per needed package
using a fully specified search: depth-first, newest version first, with
chronological backtracking. The result is therefore deterministic; if no
resolution exists it reports `unsatisfiable`.

Supported ranges: `*`, exact `X.Y.Z`, `^X.Y.Z`, `~X.Y.Z` (npm semantics) and
space-separated comparators (`<`, `<=`, `>`, `>=`). Versions are
`MAJOR.MINOR.PATCH`, compared numerically.

The search is iterative (no recursion limit), works on integer-indexed data
with per-requirement candidate index ranges found by binary search, shares
pending requirements as a persistent list, and undoes choices through a stack,
so each step costs O(1) plus the requirements it adds.

## Build

Requires Python 3.12+ and nothing else (pytest only for the tests).

```
./build.sh        # byte-compiles src/
```

## CLI

`run.sh` reads the whole input on stdin and writes the resolution to stdout
(exit status 0 in both cases).

```
$ printf 'a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n' | ./run.sh
a 1.0.0
b 1.0.0
c 1.2.5
```

Input: registry lines `name X.Y.Z: req, req` followed by a final
`root: req, req` line. Output: `name version` lines sorted by name, or the
single line `unsatisfiable`.

## Library

```python
from depresolve import Registry, Requirement, Version, parse_range, resolve, parse_input, format_resolution

# From the text format
registry, root = parse_input("a 1.0.0: b ^1.0.0\nb 1.2.0:\nb 1.1.0:\nroot: a *\n")
print(format_resolution(resolve(registry, root)), end="")

# Or build the registry in code
reg = Registry()
reg.add("a", Version(1, 0, 0), (Requirement("b", parse_range("^1.0.0")),))
reg.add("b", Version(1, 2, 0))
print(resolve(reg, [Requirement("a", parse_range("*"))]))
# {'a': Version(major=1, minor=0, patch=0), 'b': Version(major=1, minor=2, patch=0)}
```

Modules: `version` (`Version`), `ranges` (`Range`, `parse_range`), `registry`
(`Registry`, `Requirement`, `parse_input`), `resolver` (`resolve`,
`format_resolution`), `cli`.

## Tests

```
python3 -m pytest
```

The suite includes unit tests, CLI tests, and a randomised comparison against
a literal recursive transcription of the specification.
