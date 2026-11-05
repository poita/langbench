# jsonschema

A JSON Schema **draft 2020-12** validator written in Go using only the
standard library. Everything on the critical path is implemented here rather
than borrowed: the JSON parser (with exact decimal numbers), the
regular-expression engine, RFC 3986 reference resolution, RFC 6901 JSON
Pointers, the schema index (`$id` / `$anchor` / `$dynamicAnchor`) and the
keyword evaluator with annotation tracking. It passes the 2020-12 official
JSON-Schema-Test-Suite groups used by the project's test corpus.

Highlights

* **Exact numbers.** `0.3` is a multiple of `0.0001`; `1e309` is just a large
  number. No binary floating point is used for parsing, comparison, integer
  tests or `multipleOf`.
* **Code-point string lengths**, ECMA-262 regex semantics (`\b` over
  `[A-Za-z0-9_]`, `$` only at the very end).
* Full `$ref` / `$dynamicRef` / `$anchor` / `$dynamicAnchor` support, with
  remote documents supplied by the caller (nothing is ever fetched).
* `unevaluatedProperties` / `unevaluatedItems` with correct annotation
  propagation across `$ref`, `allOf`, `anyOf`, `oneOf`, `if`/`then`/`else`,
  `dependentSchemas` and `contains`.
* `format` is annotation-only and never rejects; `$vocabulary` is ignored.

## Layout

| path | role |
| --- | --- |
| `jsonschema` (root package) | `Compiler`, `Schema`: compile once, validate many instances (concurrently) |
| `jsonvalue/` | JSON data model, parser, exact `Number`, JSON equality and hashing |
| `regex/` | ECMA-262 subset regex engine (memoised backtracking, membership only) |
| `uri/` | RFC 3986 parse / resolve / recompose, percent-decoding |
| `jsonpointer/` | RFC 6901 pointer evaluation over `jsonvalue` trees |
| `cmd/jsonschema/` | the command-line tool |

## Build

Requires Go 1.27 or newer.

```sh
./build.sh          # writes bin/jsonschema
go test ./...       # unit tests
```

`build.sh` is simply `go build -o bin/jsonschema ./cmd/jsonschema`;
`run.sh` runs the resulting binary from any working directory.

## Command line

The tool reads one JSON document on stdin and prints one verdict per test:

```json
{
  "schema":  {"type": "integer", "minimum": 1},
  "tests":   [{"description": "positive", "data": 3},
              {"description": "zero",     "data": 0},
              {"description": "string",   "data": "3"}],
  "remotes": {"http://localhost:1234/other.json": {"type": "string"}}
}
```

* `schema` (required): the schema. `tests` (required): objects with a `data`
  member; `description` is ignored. `remotes` (optional): absolute URI →
  schema document, available to `$ref`/`$dynamicRef`.
* Output: `valid` or `invalid` per test, in order, one per line (here
  `valid`, `invalid`, `invalid`). Exit status 0.
* A malformed request exits with status 1 and a message on stderr. If
  validating an instance hits something unevaluable (an unresolvable
  reference, say), that instance is reported `invalid` and a warning goes to
  stderr.

```sh
echo '{"schema":{"type":"string","pattern":"^a"},"tests":[{"description":"","data":"abc"}]}' | ./run.sh
```

## Library

```go
package main

import (
	"fmt"

	"example.com/jsonschema"
	"example.com/jsonschema/jsonvalue"
)

func main() {
	schema, _ := jsonvalue.ParseString(`{
	  "$id": "https://example.com/person",
	  "type": "object",
	  "properties": {
	    "name": {"type": "string", "minLength": 1},
	    "age":  {"$ref": "nonneg.json"}
	  },
	  "required": ["name"],
	  "unevaluatedProperties": false
	}`)
	nonneg, _ := jsonvalue.ParseString(`{"type": "integer", "minimum": 0}`)

	c := jsonschema.NewCompiler()
	c.AddResource("https://example.com/nonneg.json", nonneg) // a "remote" document
	s, err := c.Compile(schema)
	if err != nil {
		panic(err)
	}

	for _, doc := range []string{
		`{"name": "Ada", "age": 36}`,
		`{"name": "Ada", "age": -1}`,
		`{"name": "Ada", "email": "x"}`,
	} {
		ok, err := s.ValidateJSON([]byte(doc))
		fmt.Println(doc, ok, err) // true / false / false, with a nil error
	}
}
```

`Compile` indexes and pre-resolves everything once; the returned `*Schema` is
immutable and safe for concurrent use. `Validate` returns an error only if it
reaches a reference that does not resolve, an invalid regular expression, or
the recursion limit (a self-referencing schema that makes no progress);
otherwise the boolean is the answer.

The supporting packages are usable on their own, e.g.
`regex.MustCompile(`^a+$`).MatchString(s)`, `jsonvalue.Equal(a, b)`,
`uri.Resolve(base, ref)` and `jsonpointer.Resolve(&root, "/a/b")`.

## Design notes

* Schemas are compiled into an arena of typed nodes holding only the
  keywords present; evaluation never looks keywords up by name, and
  references are resolved once during compilation.
* Annotations (evaluated array indices and member positions) are positional
  bitsets, built only for nodes that can be observed by an `unevaluated*`
  keyword; non-collecting nodes short-circuit `anyOf` and `contains`.
* The dynamic scope is a stack of interned base-URI ids; `$dynamicRef`
  scans it outermost-first.
* Regexes are compiled to a small instruction program and matched by a
  depth-first search with a visited set over (instruction, position), so a
  membership test is O(program size × subject length) and nested quantifiers
  cannot blow up. Counted repetition is expanded.
* Go stacks grow on demand, so deeply nested documents need no special
  handling; a depth limit guards against reference cycles.

## Notes on the specification

Nothing in `SPEC.md` or the test corpus was found to be wrong. One point the
spec leaves open: a `$ref` that cannot be resolved is only an error when
evaluation actually reaches it; the CLI then prints `invalid` for that
instance and warns on stderr.
