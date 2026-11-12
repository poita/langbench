# json-canon

A strict [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259) JSON parser and
**canonical serializer**, written from scratch in Rust with no dependencies.

It reads one JSON document and prints it in canonical form: no whitespace,
object keys sorted in UTF-16 code-unit order with duplicates collapsed (last
value wins), minimal string escaping, and numbers echoed textually (never
rounded; only the exponent is normalized, e.g. `1E+05` → `1e5`). Invalid
documents (bad UTF-8, a BOM, trailing commas, lone surrogates, nesting deeper
than 512, …) are rejected.

## Build

```
./build.sh          # or: cargo build --release
```

The binary is `target/release/json-canon`.

## CLI

`./run.sh` reads the whole document from stdin and writes one line to stdout:
the canonical serialization, or `invalid`. The exit code is 0 in both cases.

```
$ echo '{ "b": [1, 2.50, 1E+3], "a": "héllo\/", "b": null }' | ./run.sh
{"a":"héllo/","b":null}
$ echo '[1, 2, ]' | ./run.sh
invalid
```

## Library

```rust
use json_canon::{canonicalize, parse, to_canonical_string, Value};

// One-shot:
let out = canonicalize(br#"{"b":1e+05,"a":[true,null]}"#).unwrap();
assert_eq!(out, r#"{"a":[true,null],"b":1e5}"#);

// Or work with the tree:
let value = parse(b"[1, \"x\"]").unwrap();
assert_eq!(value, Value::Array(vec![Value::Number("1".into()), Value::String("x".into())]));
assert_eq!(to_canonical_string(&value), r#"[1,"x"]"#);

// Errors carry a kind and a byte offset:
let err = canonicalize(b"[1,]").unwrap_err();
println!("{err}");
```

Modules: `utf8` (strict validation), `parser` (recursive descent, depth limit
`MAX_DEPTH` = 512), `serializer` (single-buffer canonical output, UTF-16 key
order), `value`, `error`.

## Tests

```
cargo test
```
