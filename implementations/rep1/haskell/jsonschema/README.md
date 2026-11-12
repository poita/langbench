# jsonschema

A JSON Schema **draft 2020-12** validator written from scratch in Haskell,
using only GHC's bundled libraries (`base`, `containers`, `text`, `bytestring`,
`array`).  It brings its own JSON parser, exact decimal arithmetic, regular
expression engine and RFC 3986 reference resolver, and it passes the official
JSON-Schema-Test-Suite for 2020-12 (minus the `optional/` groups).

* **Exact numbers.** Numbers are `mantissa × 10^exponent` with an arbitrary
  precision mantissa; `0.3` *is* a multiple of `0.0001`, and `1e309` is just a
  big number.
* **Full annotation support.** `unevaluatedItems` / `unevaluatedProperties`
  see through `$ref`, `$dynamicRef`, `allOf`, `anyOf`, `oneOf`, `if/then/else`
  and `dependentSchemas`, and annotations never leak out of rejected branches.
* **References.** `$id`, `$anchor`, `$dynamicAnchor`, `$ref`, `$dynamicRef`
  and the dynamic scope; remote documents are supplied by the caller (nothing
  is fetched).
* **Linear-ish regex.** `pattern` / `patternProperties` use an ECMA-262 subset
  compiled to an NFA and simulated in lock step, so a search costs O(P·L) and
  cannot blow up exponentially.
* `format` is an annotation only and never rejects.

## Build

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh            # cabal build, and copy the executable to bin/jsonschema
cabal test --enable-tests   # run the hspec / QuickCheck test suite
```

## Command-line use

`run.sh` (or `bin/jsonschema`) reads **one JSON document on stdin** and prints
one line, `valid` or `invalid`, for each instance:

```json
{
  "schema":  {"type": "integer", "minimum": 1},
  "tests":   [{"description": "positive", "data": 3},
              {"description": "zero",     "data": 0},
              {"description": "string",   "data": "3"}],
  "remotes": {"http://example.test/other.json": {"type": "string"}}
}
```

```
$ ./run.sh < request.json
valid
invalid
invalid
```

| member    | required | meaning                                                         |
| --------- | -------- | --------------------------------------------------------------- |
| `schema`  | yes      | the schema (an object or a boolean)                             |
| `tests`   | yes      | array of objects, each with a `data` member (`description` is ignored) |
| `remotes` | no       | object mapping absolute URIs to schema documents                |

Other members are ignored.  The exit status is 0 on success; a document that
is not valid JSON or lacks `schema`/`tests` produces a message on stderr and
exit status 1.

## Library use

```haskell
{-# LANGUAGE OverloadedStrings #-}
import JsonSchema

main :: IO ()
main = do
  let Right schemaDoc = parseJson
        "{\"type\":\"array\",\"items\":{\"$ref\":\"#/$defs/pos\"},\
        \ \"$defs\":{\"pos\":{\"type\":\"integer\",\"minimum\":1}}}"
      schema = compileSchema schemaDoc []   -- [] = no remote documents
      check txt = either (error . show) (validate schema) (parseJson txt)
  print (check "[1, 2, 3]")   -- True
  print (check "[1, 0]")      -- False
  print (check "[1.0]")       -- True  (1.0 is an integer)
```

`compileSchema` decodes the schema once (keywords, patterns, reference
targets); the resulting `Schema` can be reused for any number of instances
with `validate`.

### Modules

| module                | responsibility                                                    |
| --------------------- | ----------------------------------------------------------------- |
| `JsonSchema`          | public facade: `compileSchema`, `validate`, JSON re-exports       |
| `JsonSchema.Json`     | `Value`, parser, renderer, JSON equality and hashing              |
| `JsonSchema.Number`   | exact decimals: comparison, integer test, exact `multipleOf`      |
| `JsonSchema.Regex`    | ECMA-262 subset: parser, NFA compiler, unanchored search          |
| `JsonSchema.Uri`      | RFC 3986 parse / resolve / `remove_dot_segments`, percent-decoding |
| `JsonSchema.Pointer`  | RFC 6901 JSON Pointer parsing and evaluation                      |
| `JsonSchema.Schema`   | compiled schema nodes, the `$id`/anchor index, reference wiring   |
| `JsonSchema.Validate` | the evaluator with annotation collection and dynamic scope        |
| `JsonSchema.Document` | the stdin/stdout request format used by the CLI                   |

## Design notes

* The schema index is a lazily tied knot: nodes reach their `$ref` targets
  through the registry, which is built from the same nodes, so every reference
  is resolved at most once.  A `$ref` whose target cannot be found rejects.
* Objects are `Data.Map`s (member order never affects a verdict), so member
  lookup is O(log n) rather than hashed O(1); `uniqueItems` uses a hash
  consistent with JSON equality and is expected linear.
* A pattern outside the supported regex subset never matches.
* Unsupported (by design): `$vocabulary` switching, `format` assertion,
  `\p{…}` escapes, look-around and backreferences.
