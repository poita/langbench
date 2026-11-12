# jsonschema

A JSON Schema **draft 2020-12** validator in Go, built only on the standard
library. It comes as a reusable library and a thin command-line tool.

Everything the validator needs is implemented here rather than imported: the
JSON parser, exact-decimal arithmetic, an ECMA-262 regular-expression engine,
RFC 3986 reference resolution, and the schema evaluator with annotation
tracking.

- Numbers are **exact decimals**: `1`, `1.0` and `1e0` are the same number, and
  `0.3` is a multiple of `0.0001`. Nothing is ever rounded to a `float64`.
- `$ref`, `$dynamicRef`, `$anchor`, `$dynamicAnchor` and nested `$id` resources
  all work, across any number of supplied documents. Nothing is fetched from
  the network.
- `unevaluatedItems` / `unevaluatedProperties` follow the annotation rules of
  the specification (`allOf`, `anyOf`, `oneOf`, `if`/`then`/`else`, `$ref`, ...).
- `pattern` / `patternProperties` run on a Thompson-style matcher: O(pattern ×
  string), no exponential backtracking.
- `uniqueItems` is linear (hashing consistent with JSON equality).
- `format` is an annotation only; `$vocabulary` and `$schema` are ignored.

## Layout

| package | responsibility |
| --- | --- |
| `example.com/jsonschema` | compile schemas, validate instances (`Compiler`, `Schema`) |
| `.../jsonvalue` | JSON data model, strict parser, exact `Number`, equality and hashing |
| `.../regex` | ECMA-262 regular-expression subset, membership matching |
| `.../uri` | RFC 3986 parsing, reference resolution, percent-decoding |
| `.../jsonpointer` | RFC 6901 JSON Pointer |
| `cmd/jsonschema` | the command-line tool |

## Build

Requires Go 1.27 or newer.

```sh
./build.sh          # builds bin/jsonschema
go test ./...       # runs the tests
```

`run.sh` runs the built binary from any directory.

## Command line

`jsonschema` reads one JSON document on standard input:

```json
{
  "schema":  {"type": "integer", "minimum": 1},
  "tests":   [{"description": "positive", "data": 3},
              {"description": "zero",     "data": 0},
              {"description": "string",   "data": "3"}],
  "remotes": {"http://example.com/other.json": {"type": "string"}}
}
```

- `schema` (required): the schema, any JSON value (normally an object or boolean).
- `tests` (required): instances to check; each needs a `data` member.
  `description` and any other members are ignored.
- `remotes` (optional): documents the schema may reference by absolute URI,
  keyed by their retrieval URI.

It prints `valid` or `invalid` for each test, one per line, and exits 0:

```console
$ ./run.sh < request.json
valid
invalid
invalid
```

Malformed input (invalid JSON, a missing member, an invalid regular expression
in the schema) is reported on stderr with exit status 1.

## Library

```go
package main

import (
	"fmt"

	"example.com/jsonschema"
	"example.com/jsonschema/jsonvalue"
)

func main() {
	// Parse with exact numbers, then compile once and validate many times.
	schemaDoc, _ := jsonvalue.ParseString(`{
		"type": "object",
		"properties": {"price": {"$ref": "http://example.com/positive.json"}},
		"required": ["price"],
		"unevaluatedProperties": false
	}`)

	var c jsonschema.Compiler
	positive, _ := jsonvalue.ParseString(`{"type": "number", "exclusiveMinimum": 0}`)
	c.AddResource("http://example.com/positive.json", positive) // no network access

	schema, err := c.Compile(schemaDoc)
	if err != nil {
		panic(err) // e.g. an invalid "pattern"
	}

	for _, doc := range []string{`{"price": 9.99}`, `{"price": 0}`, `{"price": 1, "x": 2}`} {
		inst, _ := jsonvalue.ParseString(doc)
		fmt.Println(doc, schema.Validate(inst))
	}
	// {"price": 9.99} true
	// {"price": 0} false
	// {"price": 1, "x": 2} false
}
```

For a self-contained schema, `jsonschema.CompileJSON(data)` and
`schema.ValidateJSON(data)` work directly on bytes. A compiled `*Schema` is
immutable and safe for concurrent use.

Notes on behaviour:

- `Validate` answers valid/invalid only; it does not describe errors.
- `Compile` fails only on problems detectable up front (such as a bad regular
  expression). A reference that cannot be resolved does not fail compilation
  since it may never be reached; `Schema.Unresolved()` lists them, and
  validation rejects at a dangling reference it reaches.
- Keywords with a wrongly typed value are ignored, as unknown keywords are.
- Regular expressions are the ECMA-262 subset documented in package `regex`
  (no lookaround, backreferences, named groups or `\p{...}`).
