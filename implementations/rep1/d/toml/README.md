# toml

A TOML 1.0.0 parser and serializer written in D, with a small command-line
tool that speaks the [toml-test](https://github.com/toml-lang/toml-test)
"tagged JSON" format. It uses only the D standard library (and the C runtime
for correctly rounded float conversion).

* **Decoder** – strict, single-pass recursive-descent parser. Rejects invalid
  UTF-8, stray CRs, BOMs, bad escapes, out-of-range numbers and dates, and every
  table/key redefinition forbidden by the spec. Scalars are kept as canonical text.
* **Encoder** – deterministic, canonical TOML output (sorted keys, pairs before
  tables, every table with an explicit header). `decode(encode(x)) == x`.
* **Tagged JSON** – compact, key-sorted writer and a tolerant reader.

## Layout

| Module            | Responsibility                                            |
|-------------------|-----------------------------------------------------------|
| `toml`            | package module re-exporting the public API                |
| `toml.value`      | `Node` document tree and `Kind`                           |
| `toml.parser`     | `parse`: TOML text to `Node`                              |
| `toml.encoder`    | `toToml`: `Node` to canonical TOML                        |
| `toml.json`       | `toTaggedJson` / `fromTaggedJson`                         |
| `toml.number`     | integer and float literals, canonical float text          |
| `toml.datetime`   | date/time validation and canonicalisation (textual)       |
| `toml.utf8`       | strict UTF-8 validation                                   |
| `toml.exception`  | `TomlException` (with line and column)                    |
| `app`             | the command-line tool                                     |

## Build

Requires LDC and dub.

```sh
dub build -b release --compiler=ldc2     # produces bin/toml
dub test --compiler=ldc2                 # runs the unit tests
```

`./build.sh` builds, and `./run.sh` runs the tool from any directory.

## Command line

The tool reads all of stdin. The first line is the mode; the rest is the document.

```sh
printf 'decode\nname = "Tom"\nports = [1, 2]\n' | ./run.sh
# {"name":{"type":"string","value":"Tom"},"ports":[{"type":"integer","value":"1"},{"type":"integer","value":"2"}]}

printf 'decode\na = \n' | ./run.sh          # error
{ echo encode; echo '{"a":{"type":"integer","value":"1"}}'; } | ./run.sh
# a = 1
```

`decode` prints one line of tagged JSON, or `error` for an invalid document;
`encode` prints canonical TOML. The exit code is always 0.

Floats are printed as `%.16e` (17 significant digits); date-times are
normalised textually (`T` separator, trailing fractional zeros removed,
`+00:00`/`-00:00` becomes `Z`). See `problems/toml/SPEC.md` for the full format.

## Library example

```d
import toml;

void main()
{
    auto doc = parse(`
        title = "Example"
        [owner]
        name = "Tom"
        ports = [8001, 8002]
    `);

    assert(doc["title"].asString == "Example");
    assert(doc["owner"]["ports"][1].asLong == 8002);

    string toml = toToml(doc);           // canonical TOML
    string json = toTaggedJson(doc);     // tagged JSON
    assert(toToml(fromTaggedJson(json)) == toml);

    try
        parse("a = 1\na = 2");
    catch (TomlException e)
        assert(e.line == 2);             // errors carry a position
}
```

Use it from another dub project with `dependency "toml" path="../toml"` and
`subConfiguration "toml" "library"`, which leaves out the command-line tool.
