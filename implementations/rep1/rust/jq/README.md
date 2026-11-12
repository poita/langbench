# jqlite

An interpreter for a subset of the [jq](https://jqlang.github.io/jq/) filter language
(semantics of jq 1.7, `jq -c`), written in Rust using only the standard library. It
contains its own JSON parser, JSON serializer, filter parser and tree-walking evaluator,
and is usable both as a library and as a command-line tool.

## Supported language

Identity, field/index/slice/iterate paths with `?`, pipes and commas, literals, array and
object construction (including computed keys and `{a}` / `{$x}` shorthand), arithmetic and
comparison operators, `and` / `or`, `if`/`elif`/`else`, `as` bindings, `reduce`, and the
builtins `empty error not length keys has type add select map sort sort_by group_by unique
reverse min max tostring tonumber`.

Generators follow jq's ordering rules (for `f op g` the right operand is the outer loop);
objects keep insertion order; numbers are IEEE-754 doubles printed in shortest round-trip form.

## Build

```sh
cargo build --release      # or ./build.sh
cargo test                 # unit and integration tests
```

The binary is `target/release/jqlite`; `./run.sh` runs it from any directory.

## Command-line usage

Standard input holds the **filter on the first line** and one **JSON document after it**.
Each result is printed as one line of compact JSON. If evaluation raises an uncaught error,
the results produced so far are printed followed by a line `error`. The exit status is 0
(2 if the filter or document cannot be parsed, with a message on stderr).

```console
$ printf '.users | map(select(.age >= 30) | .name)\n{"users":[{"name":"ann","age":31},{"name":"bob","age":25}]}' | ./run.sh
["ann"]
$ printf '[(1,2) + (10,20)]\nnull\n' | ./run.sh
[11,12,21,22]
```

## Library usage

```rust
use jqlite::{Filter, Value};

fn main() -> Result<(), jqlite::Error> {
    let filter = Filter::parse(".[] | select(.n > 1) | .n * 10")?;
    let doc = Value::from_json(r#"[{"n":1},{"n":2},{"n":3}]"#)?;

    // Stream results as they are produced...
    filter.run(&doc, |v| println!("{v}"))?; // prints 20 and 30

    // ...or gather them.
    let all = filter.collect(&doc)?;
    assert_eq!(all.len(), 2);
    Ok(())
}
```

## Layout

| Module | Responsibility |
|---|---|
| `value` | `Value` (reference-counted, immutable) and the total ordering |
| `object` | `Object`: insertion-ordered map, O(1) lookup, key order sorted at most once |
| `json` | JSON parser and compact serializer |
| `lexer`, `parser`, `ast` | filter text → syntax tree (recursive descent) |
| `eval`, `ops`, `builtins` | callback-style lazy evaluator, arithmetic, builtin functions |
| `error` | the `Error` type |

Design notes: values are shared and never deep-copied; sorting is a stable comparison sort with
one key evaluation per element; `add` appends in place so it is linear in the total size.
