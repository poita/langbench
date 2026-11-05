# canonjson

A strict JSON (RFC 8259) parser and canonical serializer in D, written from
scratch with only the D standard library. It is a reusable library plus a thin
command-line tool.

`canonjson` reads one JSON document, rejects anything that is not valid
(including invalid UTF-8, a byte-order mark, lone surrogates, leading zeros,
trailing commas and nesting deeper than 512), and otherwise prints its
*canonical form*:

- no whitespace outside strings;
- object keys deduplicated (the last occurrence wins) and sorted by their
  UTF-16 code unit sequences, so supplementary characters sort before
  U+E000–U+FFFF;
- strings escape only `"`, `\`, and U+0000–U+001F (`\b \f \n \r \t`, otherwise
  lowercase `\u00xx`); `/`, DEL, U+2028 and all non-ASCII are emitted raw;
- numbers are echoed textually (never converted to floating point, so integers
  of any size survive); an exponent is normalised to lowercase `e`, no `+`, no
  leading zeros (`1E+05` → `1e5`, `1e-0` → `1e0`).

## Requirements

LDC 1.41.0 and dub 1.40.0.

## Build

```sh
./build.sh          # dub build -b release --compiler=ldc2 --config=cli  → bin/canonjson
```

Run the unit tests:

```sh
dub test --compiler=ldc2
```

## Command line

```sh
echo '{ "b": [1, 2.50, 1E+3], "a": "héllo\/", "b": null }' | ./run.sh
# {"a":"héllo/","b":null}

echo '[1, 2, ]' | ./run.sh
# invalid
```

The whole of stdin is the document. stdout is a single line ending in `\n`:
either the canonical form or the word `invalid`. The exit code is 0 in both
cases; stderr is unused.

## Library

Add the package as a dub dependency (configuration `library`) or import the
sources from `source/`.

```d
import canonjson;

void main()
{
    // One-shot: parse + serialize.
    assert(canonicalize(`{ "b": [1, 2.50, 1E+3], "a": "x", "b": null }`)
           == `{"a":"x","b":null}`);

    // Parse once, inspect the tree, then serialize.
    auto doc = parse(`{"n": 1e+05, "list": [true, null]}`);
    assert(doc.kind == Kind.object);
    foreach (m; doc.object)               // members in input order
        if (m.key == cast(const(ubyte)[]) "list")
            assert(m.value.array.length == 2);
    assert(cast(string) toCanonical(doc) == `{"list":[true,null],"n":1e5}`);

    // Invalid input throws ParseException, or use the non-throwing variants.
    ubyte[] output;
    assert(!tryCanonicalize(cast(const(ubyte)[]) "[1,]", output));
}
```

Strings that contain no escapes and numbers without an exponent *borrow* from
the input buffer, so keep the input alive while using the `Value` tree.

### Modules

| Module                | Responsibility                                                       |
|-----------------------|----------------------------------------------------------------------|
| `canonjson`           | package module; `canonicalize`, `tryCanonicalize`; re-exports the rest |
| `canonjson.parser`    | `parse`, `tryParse`, `ParseException`, `maxDepth`                    |
| `canonjson.value`     | `Value`, `Kind`, `Member`: the document tree                         |
| `canonjson.serializer`| `serialize`, `toCanonical`, `writeString`                            |
| `canonjson.keyorder`  | `compareKeys`: UTF-16 order computed directly on UTF-8 bytes         |
| `canonjson.utf8`      | strict UTF-8 validation and encoding                                 |
| `canonjson.buffer`    | `ByteBuffer`, a growable byte buffer                                 |
| `canonjson.scan`      | internal byte-scanning helpers (8 bytes at a time)                   |

## Design

- The input is read whole and validated as UTF-8 in one linear pass, then
  parsed with a single-pass recursive-descent parser over bytes. The first error
  aborts the parse by throwing `ParseException`; recursion is bounded by the
  512-level depth check.
- Children are collected on shared scratch stacks and copied out once when a
  container closes, so the tree costs O(n) in total.
- The tree is serialized once, in pre-order, into one buffer. Each object sorts
  an array of small member-index handles (ties broken by input index), then keeps
  the last member of each run of equal keys. Keys are compared bytewise with a
  fix-up for the first differing character, so no per-comparison allocation or
  UTF-16 conversion happens.
- Strings are scanned in runs (8 bytes per step) and copied in bulk, both when
  parsing and when escaping.

## Layout

```
dub.json  build.sh  run.sh
source/canonjson/   the library
app/main.d          the CLI
tests/              unit tests (separate from the library source)
```
