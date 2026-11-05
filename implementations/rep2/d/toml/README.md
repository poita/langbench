# toml

A TOML 1.0.0 parser and serializer written in D using only the standard
library (druntime/Phobos), plus a small command-line tool.

* **Decode**: parses a TOML document into a tree (`toml.node.Node`) and
  prints it as [toml-test](https://github.com/toml-lang/toml-test) *tagged
  JSON* — compact, key-sorted, every scalar as `{"type": …, "value": "…"}`.
* **Encode**: reads tagged JSON and prints a canonical TOML document, so that
  `decode(encode(x)) == x`.

The parser is strict: invalid UTF-8, BOMs, lone CRs, control characters,
bad escapes, out-of-range integers/dates and every table-redefinition rule of
the TOML spec are rejected. The TOML implementation is hand-written
(no `std.datetime` parsing, no third-party code).

## Layout

```
dub.json                 project manifest (configurations: cli, library, unittest)
source/toml/
    package.d            `import toml;` re-exports the public API
    node.d               Node tree, Kind and Origin enums
    decoder.d            parseToml: recursive-descent TOML parser
    jsonwriter.d         toTaggedJson: Node -> compact key-sorted tagged JSON
    jsonreader.d         fromTaggedJson: tagged JSON -> Node
    encoder.d            toToml: Node -> canonical TOML
    floatfmt.d           strtod / "%.16e" float conversion
    utf8.d               strict UTF-8 validation and encoding
    errors.d             TomlException
app/main.d               the command-line tool
tests/toml/*_test.d      unit tests (separate from the library sources)
build.sh, run.sh         build and run helpers
```

## Building

Requires LDC and dub.

```
./build.sh                                  # dub build -b release --compiler=ldc2
dub test --compiler=ldc2                    # run the unit tests
```

The executable is written to `./toml`.

## Command-line use

The tool reads all of stdin. The first line is the mode, `decode` or
`encode`; the rest is the document. The result goes to stdout, ends with a
newline, and the exit status is 0. In decode mode an invalid document prints
just `error`.

```
$ printf 'decode\nname = "Tom"\n[db]\nports = [8001, 8002]\n' | ./run.sh
{"db":{"ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]},"name":{"type":"string","value":"Tom"}}

$ printf 'encode\n{"a":{"type":"integer","value":"1"}}' | ./run.sh
a = 1
```

Scalar text forms: integers in decimal; floats as `%.16e` (17 significant
digits, e.g. `3.1415000000000002e+00`) or `inf`/`-inf`/`nan`; date-times
canonicalised textually (`T` separator, trailing fractional zeros removed,
`Z` for UTC offsets).

## Library use

```d
import std.stdio;
import toml;

void main()
{
    auto doc = parseToml(`
        title = "Example"
        [server]
        ports = [8001, 8002]
        started = 1979-05-27T07:32:00Z
    `);

    writeln(doc["title"].str);                 // Example
    writeln(doc["server"]["ports"][1].integer); // 8002
    writeln(doc["server"]["started"].text);     // 1979-05-27T07:32:00Z

    writeln(toTaggedJson(doc));                 // tagged JSON, one line
    write(toToml(fromTaggedJson(toTaggedJson(doc)))); // canonical TOML

    try
        parseToml("a = 1\na = 2");
    catch (TomlException e)
        writeln("invalid: ", e.msg, " at byte ", e.offset);
}
```

To use it from another dub project, depend on this package and use the
`library` configuration (`"subConfigurations": {"toml": "library"}`).

## Public API

| Symbol | Purpose |
|--------|---------|
| `Node parseToml(string)` / `parseToml(const(ubyte)[])` | parse a document; throws `TomlException` |
| `string toTaggedJson(Node)` | decode-mode output |
| `Node fromTaggedJson(string)` | encode-mode input |
| `string toToml(Node)` | canonical TOML |
| `Node` | `kind`, `opIndex(string)`, `opIndex(size_t)`, `in`, `length`, `str`, `integer`, `floating`, `boolean`, `text`, `members`, `items`, `sortedKeys` |
| `Kind`, `Origin` | node kinds; how a table was created (implicit / explicit / dotted / inline) |
