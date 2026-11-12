# tomlcodec

A from-scratch **TOML 1.0.0** parser and canonical serializer in Rust, using only
the standard library. It comes as a reusable library plus a small command-line
tool that converts between TOML and the *tagged JSON* format used by the
[`toml-test`](https://github.com/toml-lang/toml-test) suite.

* **Decode**: TOML → compact, key-sorted tagged JSON (or `error` for invalid TOML).
* **Encode**: tagged JSON → canonical TOML (`decode(encode(x)) == x`).

Scalars are kept as canonical text: integers in decimal, floats as 17 significant
digits (`%.16e` style), date-times as RFC 3339 text with an uppercase `T`,
trimmed fractional seconds and `Z` for UTC.

## Building

```sh
cargo build --release      # or ./build.sh
cargo test                 # unit, integration and doc tests
```

The binary is `target/release/tomlcodec`; `./run.sh` runs it from any directory.

## Command-line usage

Standard input is a mode line (`decode` or `encode`) followed by the document;
the result goes to standard output.

```console
$ printf 'decode\nname = "Tom"\nports = [8001, 8002]\n' | ./run.sh
{"name":{"type":"string","value":"Tom"},"ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]}

$ printf 'encode\n{"a":{"type":"integer","value":"1"}}' | ./run.sh
a = 1

$ printf 'decode\na = \n' | ./run.sh
error
```

Invalid TOML is reported as the single line `error` with exit status 0. Input
that is not valid UTF-8, starts with a byte-order mark, or contains a bare CR is
invalid TOML. Mode-line problems and malformed JSON in encode mode print a
message to stderr and exit with status 2.

## Library usage

```rust
use tomlcodec::{parse, tagged_json, to_toml};

let doc = parse("name = \"Tom\"\n[db]\nports = [8001, 8002]\n")?;
assert_eq!(doc.get("name").and_then(|v| v.as_str()), Some("Tom"));

let json = tagged_json::to_string(&doc);           // tagged JSON
let toml = to_toml(&doc)?;                         // canonical TOML
assert_eq!(parse(&toml)?, doc);                    // round trip
let again = tagged_json::from_str(&json)?;         // read tagged JSON back
assert_eq!(again, doc);
# Ok::<(), Box<dyn std::error::Error>>(())
```

Errors carry a message plus line and column: `ParseError::{message, line, column}`.

### Layout

| module | responsibility |
|--------|----------------|
| `value` | data model: `Value`, `Table`, `Scalar`, `ScalarKind` |
| `parser` (private) | single-pass recursive-descent decoder |
| `tables` (private) | explicit / implicit / dotted / inline table rules |
| `number`, `datetime` (private) | integer, float and date-time validation and canonical text |
| `tagged_json` | tagged JSON reader and writer |
| `encoder` | canonical TOML output |
| `protocol` | the stdin/stdout protocol used by the CLI |

Decoding and encoding are linear in the input size (plus sorting of each table's
keys). Nesting of arrays and inline tables is limited to 2000 levels; the CLI
runs on a large stack so deep documents are fine.
