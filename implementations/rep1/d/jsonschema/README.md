# jsonschema

A [JSON Schema](https://json-schema.org/) **draft 2020-12** validator written in
D, with no dependencies beyond the D standard library. The JSON parser, the
regular-expression engine, the URI machinery and the validator are all
implemented here; nothing is delegated to `std.json`, `std.regex` or another
validator.

Highlights:

* **Exact numbers.** Numbers are arbitrary-precision decimals, never binary
  floats: `0.3` is a multiple of `0.0001`, and `1e309` is just a large number.
* **Full 2020-12 applicator set**, including `$ref`, `$anchor`, `$dynamicRef` /
  `$dynamicAnchor`, `unevaluatedItems` / `unevaluatedProperties` with
  annotation collection, `contains` with `minContains` / `maxContains`, and
  `if` / `then` / `else`.
* **ECMA-262 regular expressions** for `pattern` / `patternProperties`,
  matched in O(pattern · subject) time by an NFA simulation (no catastrophic
  backtracking).
* `format` is annotation-only; `$vocabulary` is ignored.
* Schemas refer to other documents only through a caller-supplied bundle of
  *remotes*; nothing is fetched from the network.

## Layout

```
dub.json                  package manifest (application + unittest configurations)
build.sh / run.sh         build and run the command-line tool
source/app.d              the command-line tool (thin wrapper over the library)
source/jsonschema/
  package.d               `import jsonschema;` re-exports the public API
  validator.d             Validator: the main entry point
  request.d               the CLI's request/response format as a library function
  json.d                  Value tree, parser, equality, hashing, printer
  number.d                exact decimal Number
  regex.d                 ECMA-262 subset regex engine
  uri.d, pointer.d        RFC 3986 resolution, RFC 6901 pointers
  compiler.d, node.d      schema compiler / registry and the compiled node type
  evaluator.d             the evaluator with annotation collection
tests/                    unit tests (one *_test.d module per area)
```

## Building

Requires LDC and dub (developed with LDC 1.41.0 and dub 1.40.0).

```sh
./build.sh                                # same as: dub build -b release --compiler=ldc2
dub test --compiler=ldc2                  # run the unit tests
```

The executable is written to `./jsonschema`.

## Command-line usage

The tool reads one JSON document on stdin and prints `valid` or `invalid` for
each instance, one per line.

```json
{
  "schema":  { "type": "integer", "minimum": 1 },
  "tests":   [ { "description": "positive", "data": 3 },
               { "description": "zero",     "data": 0 },
               { "description": "string",   "data": "3" } ],
  "remotes": { "http://example.test/other.json": { "type": "string" } }
}
```

```sh
$ ./run.sh < request.json
valid
invalid
invalid
```

* `schema` (required): the schema, any JSON value (normally an object or boolean).
* `tests` (required): an array of objects with a `data` member; `description`
  and other members are ignored.
* `remotes` (optional): an object mapping absolute URIs to schema documents,
  available to `$ref` / `$dynamicRef`.

The exit status is 0 on success. A malformed request or an uncompilable schema
(for example an invalid `pattern`) prints a message on stderr and exits 1.

## Using the library

```d
import std.stdio : writeln;
import jsonschema;

void main()
{
    auto validator = new Validator;

    // Documents that the schema refers to by absolute URI.
    validator.addRemote("http://example.test/positive.json",
        parseJson(`{"type": "integer", "exclusiveMinimum": 0}`));

    validator.setSchema(parseJson(`{
        "type": "object",
        "properties": {
            "id":   {"$ref": "http://example.test/positive.json"},
            "name": {"type": "string", "pattern": "^[A-Z]"}
        },
        "required": ["id"],
        "unevaluatedProperties": false
    }`));

    writeln(validator.isValid(parseJson(`{"id": 1, "name": "Ada"}`)));  // true
    writeln(validator.isValid(parseJson(`{"id": 0}`)));                 // false
    writeln(validator.isValid(parseJson(`{"id": 1, "extra": true}`)));  // false
}
```

The smaller pieces are usable on their own: `parseJson` / `Value` / `jsonEqual`
(`jsonschema.json`), `Number` and `isMultipleOf` (`jsonschema.number`),
`Regex.matches` (`jsonschema.regex`), `resolve` and `percentDecode`
(`jsonschema.uri`), and `evaluatePointer` (`jsonschema.pointer`).

### Notes

* `Validator` is not thread-safe; use one per thread.
* Evaluation and parsing are recursive. For deeply nested inputs run them on a
  thread with a large stack, as `source/app.d` does (1 GiB, reserved lazily).
* `Validator.setSchema` throws `SchemaException` for an invalid regular
  expression; `parseJson` throws `JsonException` for malformed JSON.

## Design

Documents are parsed once into a `Value` tree, then compiled in a single walk
into `Node`s (one per schema object) with keywords decoded, regexes compiled,
and `$ref` / `$dynamicRef` targets resolved once. Evaluation never looks at the
raw schema. Annotations (evaluated array indices and object member positions)
are positional bitsets, built only when an `unevaluated*` keyword can observe
them. The dynamic scope is a stack of interned base-URI ids.
