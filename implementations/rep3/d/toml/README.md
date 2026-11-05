# toml

A TOML 1.0.0 parser and serializer written in D, using only the standard
library (Phobos and druntime). It comes as a reusable library plus a small
command-line tool that converts between TOML and the *tagged JSON* format of
the [toml-test](https://github.com/toml-lang/toml-test) suite.

* **Parser**: a single-pass recursive-descent parser that rejects every
  invalid TOML 1.0.0 document (strict UTF-8, lone CRs, BOM, control
  characters, bad escapes, date/number ranges, table-redefinition rules).
* **Tagged JSON**: compact, key-sorted output; floats use the fixed
  17-significant-digit form (`%.16e`).
* **Canonical TOML writer**: deterministic output that round-trips through the
  parser.

## Build

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh                 # dub build -b release --compiler=ldc2  ->  bin/toml
dub test --compiler=ldc2   # run the unit tests (tests/)
```

## Command-line use

`bin/toml` (or `./run.sh`) reads stdin. The first line is the mode, the rest is
the document:

```sh
printf 'decode\nname = "Tom"\nports = [8001, 8002]\n' | ./run.sh
# {"name":{"type":"string","value":"Tom"},"ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]}

printf 'encode\n{"a":{"type":"integer","value":"1"}}' | ./run.sh
# a = 1
```

* `decode`: TOML to tagged JSON; prints `error` if the document is invalid.
* `encode`: tagged JSON to canonical TOML (pairs first, then `[tables]` and
  `[[arrays of tables]]`, keys in code-point order).

The exit code is always 0.

## Library

The package `toml` (import `toml;`) exposes:

| Function / type | Purpose |
|---|---|
| `Node parseToml(string)` | Parse a document; throws `TomlException` if invalid |
| `string toTaggedJson(Node)` | Compact, key-sorted tagged JSON |
| `Node fromTaggedJson(string)` | Parse tagged JSON into a tree |
| `string toToml(Node)` | Canonical TOML text |
| `Node`, `Kind` | The tree: tables, arrays and scalars with typed accessors |

Source layout (`source/toml/`): `parser.d` (grammar and table rules),
`number.d` and `datetime.d` (scalar literals), `utf8.d` (document validation),
`json.d` (tagged JSON reader/writer), `encoder.d` (TOML writer), `node.d`
(tree), `exception.d`.

```d
import toml;
import std.stdio;

void main()
{
    auto doc = parseToml(`
        title = "example"
        [server]
        ports = [8001, 8002]
    `);

    writeln(doc["title"].asString);                // example
    writeln(doc["server"]["ports"][1].asLong);     // 8002

    writeln(toTaggedJson(doc));                    // tagged JSON
    write(toToml(doc));                            // canonical TOML
}
```

Scalars are stored as canonical text (`Node.text`); `asString`, `asLong`,
`asDouble` and `asBool` convert on demand. Date-times are kept as text (no
calendar arithmetic).

## Tests

Unit tests live in `tests/` (separate from the library sources) and run with
`dub test --compiler=ldc2`. The end-to-end suite is run from the repository
root with `python3 run_tests.py toml -- toml/run.sh`.
