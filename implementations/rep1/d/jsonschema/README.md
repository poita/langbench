# jsonschema

A from-scratch validator for [JSON Schema](https://json-schema.org) draft
2020-12, written in D. It is a small library plus a thin command-line tool, and
uses nothing but the D standard library: the JSON parser, the regular-expression
engine, the RFC 3986 URI handling and the validator are all implemented here.

Highlights:

- Exact decimal arithmetic (`0.3` is a multiple of `0.0001`; `1e309` is just a
  big number) via arbitrary-precision mantissas.
- ECMA-262 style regular expressions (`pattern`, `patternProperties`) matched by
  NFA simulation: O(pattern x subject), no exponential backtracking.
- `$id`, `$anchor`, `$dynamicAnchor`, `$ref`, `$dynamicRef` and remote
  documents (nothing is ever fetched), `unevaluatedItems` /
  `unevaluatedProperties` with annotation collection.
- `format`, `$vocabulary` and the `content*` keywords are annotations only.

## Build

Requires LDC and dub (developed with LDC 1.41.0, dub 1.40.0).

```sh
./build.sh                       # same as: dub build -b release --compiler=ldc2
dub test --compiler=ldc2         # unit tests
```

This produces the executable `./jsonschema`.

## Command-line use

`./run.sh` (or `./jsonschema`) reads one JSON document on stdin and prints
`valid` or `invalid` per test instance on stdout:

```sh
echo '{
  "schema": {"type": "integer", "minimum": 1},
  "tests": [{"description": "positive", "data": 3},
            {"description": "zero", "data": 0},
            {"description": "string", "data": "3"}]
}' | ./run.sh
# valid
# invalid
# invalid
```

Input members:

| member    | required | meaning                                                   |
|-----------|----------|-----------------------------------------------------------|
| `schema`  | yes      | the schema (an object or a boolean)                       |
| `tests`   | yes      | array of `{"description": ..., "data": <instance>}`       |
| `remotes` | no       | object mapping absolute URIs to schema documents          |

Malformed input prints a message on stderr and exits with status 1.

## Library use

```d
import jsonschema;
import std.stdio;

void main()
{
    auto schema = parseJson(`{
        "$id": "https://example.test/person",
        "type": "object",
        "required": ["name"],
        "properties": {
            "name": {"type": "string", "minLength": 1},
            "age":  {"$ref": "nonneg.json"}
        },
        "unevaluatedProperties": false
    }`);
    JsonValue[string] remotes;
    remotes["https://example.test/nonneg.json"] =
        parseJson(`{"type": "integer", "minimum": 0}`);

    auto validator = new SchemaValidator(schema, remotes);
    writeln(validator.isValid(parseJson(`{"name": "Ada", "age": 36}`)));  // true
    writeln(validator.isValid(parseJson(`{"name": "Ada", "age": -1}`)));  // false
    writeln(validator.isValid(parseJson(`{"name": "Ada", "x": 1}`)));     // false
}
```

Use it as a dub dependency (`dependency "jsonschema" path="..."`, configuration
`library`).

## Layout

| module                   | responsibility                                          |
|--------------------------|---------------------------------------------------------|
| `jsonschema.number`      | exact decimal numbers (`Number`)                        |
| `jsonschema.json`        | JSON data model, parser, equality and hashing           |
| `jsonschema.uri`         | RFC 3986 resolution, percent-decoding, JSON Pointer     |
| `jsonschema.regex`       | ECMA-262 subset regex engine (membership tests)         |
| `jsonschema.schema`      | schema compilation, resource/anchor registry, `$ref`s   |
| `jsonschema.validator`   | the evaluator with annotation collection                |
| `jsonschema.runner`      | `SchemaValidator` facade and the CLI document format    |
| `app.d`                  | the command-line tool                                   |

## Notes

- Deeply nested documents are handled by evaluating on a thread with a large
  stack (see `source/app.d`); library users with very deep inputs should do
  the same.
- A `SchemaValidator` and the regex caches are not thread-safe; use one per
  thread.
