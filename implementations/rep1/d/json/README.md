# jsoncanon

A strict [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259) JSON parser and
canonical serializer, written in D with no dependencies beyond Phobos/druntime.
It doesn't use `std.json` or any other JSON library.

*Canonical* means: no whitespace outside strings, object members sorted by key
in UTF-16 code unit order, duplicate keys collapsed to the last occurrence,
only the required string escapes, and numbers echoed textually (never
converted to floating point, any size) with the exponent normalised
(`1E+05` → `1e5`).

## Layout

| Module                 | Responsibility                                           |
|------------------------|----------------------------------------------------------|
| `jsoncanon.utf8`       | strict UTF-8 validation (RFC 3629) and encoding          |
| `jsoncanon.value`      | `JsonValue` tree (numbers as text, strings decoded)      |
| `jsoncanon.parser`     | recursive-descent parser, `JsonException`, depth limit 512 |
| `jsoncanon.order`      | UTF-16 code unit comparison of UTF-8 strings             |
| `jsoncanon.serializer` | single-pass canonical writer to any output range         |
| `jsoncanon`            | `package.d`: re-exports everything, plus `canonicalize`  |
| `app`                  | the command-line tool                                    |

## Build

Requires LDC and dub (developed with LDC 1.41.0 and dub 1.40.0).

```
dub build -b release --compiler=ldc2     # or ./build.sh
```

This produces the `jsoncanon` executable in the project root.

## Command line

```
jsoncanon < input.json
```

Reads the whole of stdin as one JSON document. Prints the canonical form and a
newline, or the single line `invalid` if the document is not valid (bad
UTF-8, a BOM, a grammar violation, a lone surrogate escape, nesting deeper than
512, trailing data, ...). The exit status is 0 in both cases. `./run.sh` is a
wrapper that works from any directory.

```
$ echo '{ "b": [1, 2.50, 1E+3], "a": "héllo\/", "b": null }' | ./run.sh
{"a":"héllo/","b":null}
$ echo '[1, 2, ]' | ./run.sh
invalid
```

## Library

```d
import jsoncanon;

void main()
{
    // One call: input text -> canonical text (throws JsonException if invalid).
    assert(canonicalize(`{"b": 1e+05, "a": [true, null]}`) == `{"a":[true,null],"b":1e5}`);

    // Or work with the tree.
    JsonValue doc = parse(`{"name": "x", "tags": ["a", "b"]}`);
    assert(doc.kind == JsonKind.object);
    foreach (m; doc.members)          // input order, duplicates included
        if (m.key == "tags")
            assert(m.value.items.length == 2);

    // Serialize to any output range of const(char)[].
    import std.array : appender;
    auto sink = appender!string;
    writeCanonical(sink, doc);

    // Invalid input: throw, or use the non-throwing variant.
    JsonValue v;
    assert(!tryParse(cast(const(ubyte)[]) "[1,]", v));
}
```

To use it from another dub project:

```sdl
dependency "jsoncanon" path="../json"
subConfiguration "jsoncanon" "library"
```
and `import jsoncanon;`.

## Tests

```
dub test --compiler=ldc2
```

The tests are D `unittest` blocks next to the code they cover (UTF-8 edge
cases, grammar accept/reject tables, number normalisation, surrogate
handling, depth limits, ordering, deduplication).

## Design notes

Validation (UTF-8) and parsing are forward passes with no backtracking.
Strings without escapes are slices of the input; numbers keep their lexeme.
Children are collected on shared scratch stacks and copied out when their
container closes. Serialization writes straight to one output sink, sorting
member *indices* per object by `(key, position)` and writing the last member
of each run of equal keys. Key comparison works directly on UTF-8: byte order
equals code point order except for 4-byte sequences versus U+E000–U+FFFF.
