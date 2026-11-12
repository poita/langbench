# jsonschema

A dependency-free validator for [JSON Schema draft 2020-12](https://json-schema.org/draft/2020-12/json-schema-core),
written from scratch in Rust: its own JSON parser, exact decimal arithmetic, a
regular-expression engine, RFC 3986 reference resolution, and the schema
compiler/evaluator. Only the standard library is used.

Highlights:

* **Exact numbers.** Numbers are `mantissa × 10^exp` with an arbitrary-precision
  mantissa; no binary floating point anywhere. `0.3` is a multiple of `0.0001`,
  `1` equals `1.0` equals `1e0`, and `1e309` is simply a large number.
* **Full applicator set** including annotation-driven `unevaluatedItems` /
  `unevaluatedProperties`, `$ref`, `$dynamicRef`/`$dynamicAnchor`, `$anchor`,
  nested `$id` resources and remote documents.
* **Linear-time regexes.** `pattern` / `patternProperties` use an ECMA-262 style
  engine run as an NFA simulation: O(pattern × subject), no exponential
  backtracking.
* `format`, `$vocabulary` and the `content*` keywords are annotations only and
  never reject.

## Layout

| path | responsibility |
| --- | --- |
| `src/bigint.rs` | minimal arbitrary-precision unsigned integer |
| `src/number.rs` | exact decimal `Number` (compare, integer test, `multipleOf`) |
| `src/json.rs` | `Json` value, order-preserving `Object`, RFC 8259 parser |
| `src/regex.rs` | regex parser, compiler and NFA matcher |
| `src/uri.rs` | RFC 3986 resolution, percent-decoding, JSON Pointer escaping |
| `src/schema.rs` | schema index (`$id`/`$anchor`/`$dynamicAnchor`), keyword decoding, reference resolution |
| `src/eval.rs` | evaluator with annotation collection and dynamic scope |
| `src/main.rs` | the command-line tool |
| `tests/` | integration tests (spec examples, CLI contract, shared corpus) |

## Building

```sh
cargo build --release      # or ./build.sh
```

This produces `target/release/jsonschema-cli`. Run the tests with `cargo test`.

## Command-line use

`./run.sh` (or the binary directly) reads one JSON document on stdin and prints
`valid` or `invalid`, one line per test instance:

```json
{
  "schema": {"type": "integer", "minimum": 1},
  "tests": [
    {"description": "a positive integer", "data": 3},
    {"description": "zero", "data": 0},
    {"description": "a string", "data": "3"}
  ],
  "remotes": {"http://example.test/other.json": {"type": "string"}}
}
```

```sh
$ ./run.sh < request.json
valid
invalid
invalid
```

* `schema` – the schema (retrieval URI `""`); `tests` – instances in `data`
  members (`description` is ignored); `remotes` (optional) – documents
  addressable by absolute URI. Extra members are ignored.
* Exit status is 0 on success. Unreadable input or an unsupported pattern prints
  a message to stderr and exits non-zero.
* Validation runs on a thread with a 1 GiB (virtual) stack so very deeply
  nested schemas work.

## Library use

```rust
use jsonschema::{json, Schema};

fn main() {
    let schema = json::parse(r#"{
        "type": "object",
        "properties": {"id": {"type": "integer", "minimum": 1}},
        "required": ["id"],
        "unevaluatedProperties": false
    }"#).unwrap();

    // Remote documents are supplied up front; nothing is ever fetched.
    let schema = Schema::builder().build(&schema).unwrap();

    assert!(schema.is_valid(&json::parse(r#"{"id": 7}"#).unwrap()));
    assert!(!schema.is_valid(&json::parse(r#"{"id": 0}"#).unwrap()));
    assert!(!schema.is_valid(&json::parse(r#"{"id": 1, "extra": true}"#).unwrap()));
}
```

Public API: `json::parse` → `Json`; `Schema::compile` / `Schema::builder().remote(uri, &doc).build(&root)`
→ `Schema`; `Schema::is_valid(&Json) -> bool`. The building blocks `number::Number`,
`regex::Regex` and the `uri` functions are public as well.

`Schema` keeps pattern compilation and reference resolution out of the
validation path: both happen once in `compile`. A `Schema` is not `Sync`
(patterns are shared with `Rc`); build one per thread if you validate in
parallel.

## Regular expression subset

Alternation, `( )` and `(?: )` groups, `* + ? {n} {n,} {n,m}` (and lazy forms),
`.`, `^`, `$` (only at the very start/end of the string), `\b` `\B` (ASCII word
characters), classes `[...]` / `[^...]`, `\d \D \w \W \s \S`, and the character
escapes `\n \r \t \f \v \0 \xHH \uHHHH \cX` plus escaped punctuation. Matching is
over Unicode code points with no flags. Lookaround, backreferences, named
groups, `\p{..}` and `\u{..}` are not supported and make `Schema::compile`
return an error.
