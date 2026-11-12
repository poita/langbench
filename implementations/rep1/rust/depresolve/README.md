# depresolve

A small, dependency-free Rust library and command-line tool that resolves
package dependencies deterministically.

Given a registry of package versions (each with a list of requirements) and a
root manifest, it picks one version per needed package so that every
requirement is met. The result is the **first solution of a fixed search**:
depth-first in requirement order, newest version first, with chronological
backtracking. Every correct implementation therefore prints the same answer.
When nothing works it prints `unsatisfiable`.

The search is iterative (no recursion, so very deep dependency chains are fine).
Each search step is O(1) plus the requirements it adds: candidates are
precomputed index ranges found by binary search, the pending requirements are a
shared persistent list in an arena, and backtracking rewinds the arena and a
trail rather than copying state.

## Build

```sh
cargo build --release      # or ./build.sh
```

The binary is `target/release/depresolve` (`./run.sh` runs it).

## Command-line usage

Input is read from stdin: registry lines `name MAJOR.MINOR.PATCH: requirements`
followed by a final `root: requirements` line. Requirements are separated by
`, ` and look like `name RANGE`, where a range is `*`, `X.Y.Z`, `^X.Y.Z`,
`~X.Y.Z`, or one to three space-separated comparators (`<`, `<=`, `>`, `>=`).

```console
$ printf 'a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n' | ./run.sh
a 1.0.0
b 1.0.0
c 1.2.5
```

Output is one `name version` line per chosen package, sorted by name, or the
single line `unsatisfiable`. Both exit with status 0; malformed input prints a
message on stderr and exits with status 2.

## Library usage

```rust
use depresolve::{parse_input, resolve, Range, Registry, Requirement, Version};

// From the text format:
let input = parse_input("a 1.0.0: b ^1.0.0\nb 1.4.0:\nroot: a *\n").unwrap();
let solution = resolve(&input.registry, &input.root).unwrap();
assert_eq!(solution.get("b"), Some(Version::new(1, 4, 0)));

// Or build a registry programmatically:
let mut reg = Registry::new();
reg.add("lib", Version::new(1, 2, 0), vec![]);
let root = vec![Requirement::new("lib", "^1.0.0".parse::<Range>().unwrap())];
println!("{}", resolve(&reg, &root).unwrap());
```

Modules: `version` (semver type), `range` (range parsing and matching),
`registry` (packages and requirements), `parser` (text format), `resolver`
(the search), `error`.

## Tests

```sh
cargo test
```
