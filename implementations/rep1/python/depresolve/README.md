# depresolve

A small, dependency-free Python package dependency resolver. Given a registry
of package versions (each with its requirements) and a root manifest, it picks
one version per needed package using a fully specified search — depth-first,
newest version first, chronological backtracking — so every run prints the
same resolution, or `unsatisfiable` if none exists.

Supported ranges: `*`, exact `X.Y.Z`, `^X.Y.Z`, `~X.Y.Z` (npm semantics) and
space-separated comparator lists such as `>=1.0.0 <2.0.0`.

The search uses an explicit stack, a shared linked list of pending
requirements and an undo trail, so a step costs O(1) plus the requirements it
adds, and dependency chains thousands deep are fine.

## Build

Pure Python 3.12+ (developed on 3.14), standard library only.

```sh
./build.sh                 # byte-compiles the package
pip install -e '.[test]'   # optional: install it and pytest
```

## Command-line use

`run.sh` reads the problem on stdin and writes the resolution to stdout
(no install needed; it sets `PYTHONPATH` itself):

```sh
$ printf 'a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n' | ./run.sh
a 1.0.0
b 1.0.0
c 1.2.5
```

Input: registry lines `name X.Y.Z: req, req, ...` followed by one final
`root: req, ...` line, where a requirement is `name range`. Output: one
`name version` line per chosen package sorted by name, or `unsatisfiable`.
The exit status is 0 in both cases.

## Library use

```python
from depresolve import Registry, Requirement, Version, resolve, parse_problem

# From text:
registry, root = parse_problem("a 1.0.0: b ^1.0.0\nb 1.4.2:\nroot: a *\n")

# Or build it programmatically:
registry = Registry()
registry.add("b", Version(1, 4, 2))
registry.add("a", Version(1, 0, 0), [Requirement.parse("b ^1.0.0")])
root = [Requirement.parse("a *")]

resolution = resolve(registry, root)   # Resolution, or None if unsatisfiable
print(resolution.versions)             # {'a': Version(1, 0, 0), 'b': Version(1, 4, 2)}
print(resolution.lines())              # ['a 1.0.0', 'b 1.4.2']
```

Modules: `version` (`Version`), `ranges` (`VersionRange`, half-open key
intervals), `model` (`Requirement`, `Registry`), `parser` (`parse_problem`),
`resolver` (`resolve`, `Resolution`), `cli`.

## Tests

```sh
python3 -m pytest
```
