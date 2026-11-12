# toml

A from-scratch **TOML 1.0.0** parser and serializer for D, plus a small
command-line tool built on it. It uses only the D standard library (and the C
runtime's `strtod`/`snprintf` for correctly rounded float conversion).

* **Decode**: parse a TOML document and print it as *tagged JSON*, the
  interchange format of the [toml-test](https://github.com/toml-lang/toml-test)
  suite (compact, keys sorted, every scalar as `{"type":…,"value":…}`).
* **Encode**: read tagged JSON and print a canonical TOML document, such that
  `decode(encode(x)) == x`.

Invalid documents are rejected strictly: bad UTF-8, a BOM, stray CRs, control
characters, bad escapes, malformed numbers and dates, duplicate keys and all
the table-redefinition rules of the specification.

## Layout

| Path                     | Purpose                                              |
|--------------------------|------------------------------------------------------|
| `source/toml/node.d`     | `Node` tree, `ScalarType`, `TomlException`           |
| `source/toml/decoder.d`  | `parseToml`: recursive-descent parser + table rules  |
| `source/toml/encoder.d`  | `toToml`: canonical TOML writer                      |
| `source/toml/json.d`     | `toTaggedJson` / `fromTaggedJson`                    |
| `source/toml/datetime.d` | date/time validation and canonical text              |
| `source/toml/numbers.d`  | integer/float scanning and float formatting          |
| `source/toml/utf8.d`     | UTF-8 validation and encoding                        |
| `source/toml/convert.d`  | whole-request helpers used by the CLI                |
| `cli/main.d`             | the command-line tool (thin wrapper)                 |

Scalars are stored as their canonical *text*; dates are never converted to a
calendar type and `encode` never converts numbers, so nothing is lost.

## Build

Requires LDC and dub.

```sh
./build.sh          # dub build -b release --compiler=ldc2 --config=cli
dub test --compiler=ldc2
```

The tool is written to `bin/toml-cli`; `run.sh` runs it from any directory.

## Command line

The first line of stdin is the mode (`decode` or `encode`); the rest is the
document. The result goes to stdout and the exit code is 0.

```sh
$ printf 'decode\nname = "Tom"\nports = [1, 2]\n' | ./run.sh
{"name":{"type":"string","value":"Tom"},"ports":[{"type":"integer","value":"1"},{"type":"integer","value":"2"}]}

$ printf 'decode\na = \n' | ./run.sh
error

$ printf 'encode\n{"a":{"type":"integer","value":"1"}}' | ./run.sh
a = 1
```

A document that is not valid TOML prints `error` (with a diagnostic on
stderr). Floats print as 17 significant digits (`1.0` → `1.0000000000000000e+00`),
dates and times are canonicalised textually (`1979-05-27t07:32:00-00:00` →
`1979-05-27T07:32:00Z`).

## Library example

Add the package as a dub dependency (`dependency "toml" path="../toml"`), then:

```d
import std.stdio;
import toml;

void main()
{
    auto doc = parseToml(`
        name = "Tom"
        [db]
        ports = [ 8001, 8002 ]
    `);

    writeln(doc["name"].text);                // Tom
    writeln(doc["db"]["ports"].items.length); // 2

    writeln(toTaggedJson(doc));               // tagged JSON, one line
    write(toToml(doc));                       // canonical TOML

    try
        parseToml("a = 1\na = 2");
    catch (TomlException e)
        writeln("invalid: ", e.msg, " at byte ", e.offset);
}
```

`parseToml` accepts `const(ubyte)[]` or `string`; both throw `TomlException`
on invalid input. Walk the result via `Node.kind` (`table`, `array`,
`scalar`), `Node.entries`, `Node.items`, `Node.scalarType` and `Node.text`.

## Tests

`dub test --compiler=ldc2` runs the `unittest` blocks in each module (D's
built-in test framework): scalar scanners, date validation, string escapes,
table/array-of-tables rules, JSON round trips and the CLI request handler.
