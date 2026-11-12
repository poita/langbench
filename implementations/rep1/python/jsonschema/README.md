# jsonschema2020

A dependency-free validator for [JSON Schema](https://json-schema.org/) draft
2020-12, written in pure Python (standard library only).

It is a small, self-contained implementation: the JSON parser, the
regular-expression engine and the URI/JSON-Pointer machinery are all part of
the package, and numbers are handled as **exact decimals** (no binary floats),
so `0.3` is a multiple of `0.0001`, `1e309` is just a large number, and `1`,
`1.0` and `1e0` are the same value.

Supported: every validation and applicator keyword of 2020-12 (`type`, `enum`,
`const`, numeric / string / array / object keywords, `prefixItems`, `items`,
`contains` with `minContains`/`maxContains`, `allOf`/`anyOf`/`oneOf`/`not`,
`if`/`then`/`else`, `dependentRequired`, `dependentSchemas`,
`unevaluatedItems`, `unevaluatedProperties`), `$id`, `$anchor`,
`$dynamicAnchor`, `$ref`, `$dynamicRef`, and a bundle of remote documents.
`format`, `$vocabulary` and the content/metadata keywords are annotation-only
and never reject. Nothing is fetched from the network.

Regular expressions (`pattern`, `patternProperties`) follow ECMA-262 semantics
over Unicode code points for the common subset (groups, alternation,
quantifiers, classes, `\d\w\s`, `\b`, anchors, escapes); lookaround,
backreferences and `\p{..}` are not supported. Matching is a Thompson-NFA
simulation, so it is O(pattern x subject) with no exponential backtracking.

## Layout

```
src/jsonschema2020/
    jsonvalue.py   data model: exact numbers, JSON equality, hashing key
    jsonparse.py   recursive-descent JSON parser
    regex.py       regex parser + NFA matcher
    uri.py         RFC 3986 resolution, percent-decoding, RFC 6901 pointers
    nodes.py       compiled Node, annotation collector, schema registry
    keywords.py    one compiler per keyword
    compiler.py    schema walk: base URIs, $id/$anchor indexing, node building
    validator.py   public API (Validator, validate, check_document)
    cli.py         command-line tool
tests/             pytest suite
build.sh / run.sh  build and run scripts
```

## Build

There is nothing to compile; `build.sh` byte-compiles the package:

```sh
./build.sh
```

Requires Python 3.10+ (developed on 3.14). To run the tests:

```sh
python3 -m pytest          # from this directory; needs pytest
```

The package can also be installed in the usual way (`pip install .`), which
provides a `jsonschema2020` command; `run.sh` works without installing.

## Command line

`run.sh` reads **one JSON document on stdin**:

```json
{
  "schema": {"type": "integer", "minimum": 1},
  "tests": [
    {"description": "a positive integer", "data": 3},
    {"description": "zero", "data": 0},
    {"description": "a string", "data": "3"}
  ],
  "remotes": {"http://example.test/other.json": {"type": "string"}}
}
```

`schema` and `tests` are required; `remotes` (absolute URI -> schema document)
is optional; `description` and any other members are ignored. For each test it
prints `valid` or `invalid` on its own line, in order:

```
$ ./run.sh < input.json
valid
invalid
invalid
```

The exit status is 0 on success; on malformed input a message goes to stderr
and the status is non-zero. Deeply nested schemas and instances are fine (the
CLI runs on a large stack with a raised recursion limit).

## Library

```python
from jsonschema2020 import Validator, loads, validate

schema = loads("""
{
  "$id": "https://example.test/person",
  "type": "object",
  "properties": {
    "name": {"type": "string", "minLength": 1},
    "age":  {"type": "integer", "minimum": 0},
    "tags": {"type": "array", "items": {"$ref": "#/$defs/tag"}, "uniqueItems": true}
  },
  "required": ["name"],
  "unevaluatedProperties": false,
  "$defs": {"tag": {"type": "string", "pattern": "^[a-z]+$"}}
}
""")

validator = Validator(schema, normalized=True)   # compiled once
validator.is_valid({"name": "Ada", "age": 36, "tags": ["math"]})   # True
validator.is_valid({"name": "Ada", "extra": 1})                    # False
validator.is_valid({"age": 1})                                     # False

# One-shot form; plain Python data (floats, tuples, ...) is accepted and
# floats are converted exactly:
validate({"multipleOf": 0.0001}, 0.3)   # True
```

* `Validator(schema, remotes=None, *, normalized=False)` compiles a schema (a
  `dict` or `bool`); `remotes` maps absolute URIs to additional documents
  that `$ref` may point at.
* `Validator.is_valid(instance, *, normalized=False) -> bool`.
* `validate(schema, instance, remotes=None) -> bool`.
* `loads(text)` parses JSON exactly (integers and non-integers are `int` and
  `fractions.Fraction`; `1.0` becomes `1`); `normalize(obj)` converts ordinary
  Python data into that model; pass `normalized=True` to skip the conversion
  for data that already came from `loads`.
* Errors: `SchemaError` (unusable schema or invalid pattern),
  `RefResolutionError` (a reachable reference cannot be resolved),
  `JSONParseError` (malformed JSON).

Remote documents are indexed exactly like the root schema, using the mapping
key as their retrieval URI:

```python
Validator(
    {"$ref": "http://example.test/str.json"},
    {"http://example.test/str.json": {"type": "string"}},
).is_valid("hello")   # True
```
