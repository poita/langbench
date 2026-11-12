# jq-subset

An interpreter for a subset of the [jq](https://jqlang.github.io/jq/) filter
language (semantics of jq 1.7, `jq -c`), written in Rust with no dependencies
beyond the standard library. It has its own JSON parser and serializer and a
lazy, ordered, tree-walking evaluator.

The project is a reusable library (`jq_subset`) plus a thin command-line tool
(`jq`).

## Building

```sh
./build.sh            # or: cargo build --release
```

The binary is `target/release/jq`; `./run.sh` runs it from any directory.
Run the tests with `cargo test`.

## Command line

The program reads all of stdin. The **first line** is the filter; everything
after it is **one JSON document**. Each result is printed as a line of compact
JSON (object keys in insertion order, never sorted).

```console
$ printf '%s\n%s\n' '.users | map(select(.age >= 30)) | map(.name)' \
    '{"users":[{"name":"ann","age":31},{"name":"bob","age":25}]}' | ./run.sh
["ann"]
```

If an uncaught runtime error occurs, the results produced before it are
printed, then a line `error`, and evaluation stops. The exit status is 0 in
that case; it is nonzero only if the filter or document cannot be parsed.

### Supported language

* Paths: `.`, `.a`, `."a b"`, `.[e]`, `.[]`, `.[a:b]`, and `?` (per-operation
  tolerance after a path step, `try` after anything else).
* Literals, `$var`, `[...]`, `{...}` (including `{a}`, `{$x}`, `{(e): v}`).
* Operators: `|`, `,`, `or`, `and`, `== != < <= > >=`, `+ - * / %`, unary `-`.
* `if/elif/else/end`, `E as $x | body`, `reduce SRC as $x (INIT; UPDATE)`.
* Builtins: `empty error error(f) not length keys has(k) type add select(f)
  map(f) sort sort_by(f) group_by(f) unique reverse min max tostring
  tonumber`.

Generators follow jq's order exactly (for binary operators the right operand
is the outer loop). Arithmetic, ordering and key-order rules are those of the
specification this crate implements.

## Library

```rust
use jq_subset::{Filter, Value};

fn main() {
    let filter = Filter::parse("[.[] | select(.n > 1) | .n * 2]").unwrap();
    let doc = Value::parse_json(r#"[{"n":1},{"n":2},{"n":3}]"#).unwrap();

    // Collect every result...
    let results = filter.collect(&doc).unwrap();
    assert_eq!(results[0].to_json(), "[4,6]");

    // ...or stream them as they are produced. Results emitted before a
    // runtime error have already been delivered when `run` returns `Err`.
    filter
        .run(&doc, |v| println!("{}", v))
        .unwrap();
}
```

Modules:

| Module | Responsibility |
|---|---|
| `value`, `object` | immutable, reference-counted data model; jq's total ordering; insertion-ordered objects with O(1) lookup and a cached sorted-key order |
| `json` | JSON text ⇄ `Value` |
| `ast` | filter syntax tree |
| `error` | `Error`, `ParseError`, `JsonError` |

The parser, evaluator and builtins are internal; `Filter` is the entry point.

## Design notes

* Values are shared with `Rc`; binding, indexing, iterating and `select` never
  copy. Values are never mutated in place, except that an `Rc` held by one
  owner is reused (so `reduce ... (.; . + x)` accumulates in linear time).
* Evaluation is continuation-passing: each expression pushes its outputs into
  a callback as soon as they are produced, so output is lazy and ordered and
  an error unwinds the whole evaluation at the point it occurs.
* Sorting is a stable comparison sort with one evaluation of `[f]` per element.
