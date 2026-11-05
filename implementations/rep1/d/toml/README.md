# toml

A from-scratch TOML 1.0.0 parser and canonical serializer in D, with a small
command-line tool that speaks the `toml-test` *tagged JSON* format. It uses
only Phobos/druntime — no TOML or JSON library.

## Layout

| Path | Contents |
|------|----------|
| `source/toml/node.d` | `Node` tree, `Kind`, `TomlException` |
| `source/toml/validate.d` | strict UTF-8, BOM and lone-CR checks |
| `source/toml/scalar.d` | integer / float / date-time scanners, float formatting |
| `source/toml/parser.d` | `parse`: TOML text → `Node` tree |
| `source/toml/json.d` | `toTaggedJson` / `fromTaggedJson` |
| `source/toml/encoder.d` | `toToml`: tree → canonical TOML |
| `source/toml/package.d` | `import toml;` re-exports everything |
| `app/main.d` | the command-line tool |
| `tests/` | unit tests (run by `dub test`) |

## Building

Requires LDC 1.41 and dub 1.40.

```
./build.sh                                   # builds bin/toml-cli
dub build -b release --compiler=ldc2         # same, by hand
dub test --compiler=ldc2                     # unit tests
```

## Command line

`./run.sh` reads stdin: the first line is the mode (`decode` or `encode`), the
rest is the document.

```
$ printf 'decode\na = 1\n[t]\nb = [1.5, "x"]\n' | ./run.sh
{"a":{"type":"integer","value":"1"},"t":{"b":[{"type":"float","value":"1.5000000000000000e+00"},{"type":"string","value":"x"}]}}

$ printf 'decode\na = 1\n[t]\nb = [1.5, "x"]\n' | ./run.sh | sed '1s/^/encode\n/' | ./run.sh
a = 1

[t]
b = [1.5000000000000000e+00, "x"]
```

* `decode` prints compact, key-sorted tagged JSON, or `error` for an invalid
  document.
* `encode` prints the canonical TOML for a tagged JSON tree.
* The exit status is always 0.

## Library

```d
import std.stdio;
import toml;

void main()
{
    auto doc = parse("name = \"Tom\"\n[db]\nports = [8001, 8002]\n");

    writeln(doc["name"].asString);            // Tom
    writeln(doc["db"]["ports"][1].asInteger); // 8002

    writeln(toTaggedJson(doc));  // {"db":{"ports":[...]},"name":{...}}
    write(toToml(doc));          // canonical TOML

    try parse("a = 01");
    catch (TomlException e) writeln("line ", e.line, ": ", e.msg);
}
```

`parse` throws `TomlException` for any document that is not valid TOML 1.0.0.
Scalars keep their canonical text in `Node.text` (decimal integers, 17-digit
floats, normalised date-times); `asInteger`, `asFloat`, `asBool` and
`asString` give typed access.

## Notes

Floats are converted with the C runtime's `strtod`/`snprintf("%.16e")`, which
are correctly rounded. Everything else — lexing, table-provenance rules,
date validation, JSON — is implemented in this repository.
