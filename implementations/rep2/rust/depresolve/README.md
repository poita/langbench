# depresolve

A deterministic package dependency resolver, as a Rust library and a small
command-line tool. Given a registry (every version of every package, each with
its requirements) and a root manifest, it picks one version for every needed
package so that all requirements are met — or reports `unsatisfiable`.

The result is defined by a fixed search: depth-first in requirement order,
newest candidate first, chronological backtracking. The **first** complete
solution of that search is the answer, so it is reproducible and identical
across implementations. It is not necessarily the "globally newest" set.

The search is iterative (no recursion, so very deep dependency chains are
fine), never copies the chosen set or the pending requirements, and finds each
package's candidates by binary search over its sorted versions.

Only the Rust standard library is used.

## Build

```
./build.sh            # or: cargo build --release
```

The binary is `target/release/depresolve`; `./run.sh` runs it from any
directory.

## CLI

The program reads the whole input on stdin and writes the resolution to stdout
(exit status 0 for both outcomes; 2 on malformed input).

```
$ ./run.sh <<'IN'
a 1.0.0: c ^1.0.0
b 1.0.0: c ~1.2.0
c 1.1.0:
c 1.2.5:
c 1.3.0:
root: a *, b *
IN
a 1.0.0
b 1.0.0
c 1.2.5
```

### Input format

Zero or more registry lines followed by one root line, each ending in `\n`:

```
registry_line = name " " version ":" requirements "\n"
root_line     = "root:" requirements "\n"
requirements  = ""  |  " " requirement { ", " requirement }
requirement   = name " " range
range         = "*" | X.Y.Z | "^"X.Y.Z | "~"X.Y.Z | comparator { " " comparator }
comparator    = ("<" | "<=" | ">" | ">=") X.Y.Z
```

Ranges follow npm semantics for `^` and `~`; versions compare numerically.

### Output

One `name version` line per chosen package, sorted by name in byte order, or
the single line `unsatisfiable`. An empty root manifest prints nothing.

## Library

```rust
let input = "\
a 2.0.0: b ~1.0.0
a 1.0.0:
b 1.0.0:
b 1.0.5:
b 1.5.0:
root: a *, b *
";

// One call: parse, resolve and render as the CLI does.
assert_eq!(depresolve::resolve_str(input).unwrap(), "a 2.0.0\nb 1.0.5\n");

// Or use the pieces.
let problem = depresolve::parse(input).unwrap();
match depresolve::resolve(&problem) {
    Some(res) => {
        for (name, version) in &res.packages {
            println!("{name} {version}");
        }
    }
    None => println!("unsatisfiable"),
}
```

Registries can also be built programmatically with `RegistryBuilder`
(`add_version`, `set_root`, `build`).

Modules: `version` (versions and ranges), `registry` (interned registry with
ranges compiled to index ranges), `parser` (text format), `resolver` (the
search), `error`.

## Tests

```
cargo test --release
```

Unit tests per module, the specification's examples as integration tests, a
deep-chain test, and a differential test against a naive transcription of the
specification's recursive pseudo-code on thousands of random registries.
