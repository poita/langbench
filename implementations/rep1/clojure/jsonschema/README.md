# jsonschema

A JSON Schema **draft 2020-12** validator in Clojure, with no dependencies
beyond Clojure itself. It ships as a reusable library and as a small
command-line tool.

The JSON parser, the regular-expression engine, the RFC 3986 URI machinery and
the validator are all implemented here; no JSON, regex or JSON Schema library
is used.

Highlights:

* all 2020-12 applicator and validation keywords, including `$ref`,
  `$dynamicRef`/`$dynamicAnchor`, `$anchor`, nested `$id`, and annotation
  tracking for `unevaluatedItems` / `unevaluatedProperties`;
* **exact decimal arithmetic**: numbers are `BigDecimal`s, so `0.3` is a
  multiple of `0.0001` and `1e309` is just a large number;
* an ECMA-262-flavoured regex engine whose matching is O(pattern x subject)
  (Thompson NFA simulation; no catastrophic backtracking);
* `uniqueItems` in expected linear time (hashing consistent with JSON equality);
* schemas are compiled once into closures; references are resolved lazily.

`format` is an annotation only and never rejects; `$vocabulary` is ignored.

## Requirements

Clojure 1.12 (the `clojure` CLI) on Java 27. Nothing else is needed to run it;
the tests use `org.clojure/test.check` and the Cognitect test runner.

## Build

```sh
./build.sh
```

This AOT-compiles the command-line tool into `classes/` (which is on the
classpath, so start-up is fast). The library itself needs no build step: put
`src` on the classpath.

## Command-line use

`./run.sh` reads one JSON document on stdin and prints `valid` or `invalid`
for every test, one per line:

```sh
$ echo '{
  "schema": {"type": "integer", "minimum": 1},
  "tests": [{"description": "positive", "data": 3},
            {"description": "zero",     "data": 0},
            {"description": "string",   "data": "3"}]
}' | ./run.sh
valid
invalid
invalid
```

Input members:

| member    | required | meaning                                                      |
|-----------|----------|--------------------------------------------------------------|
| `schema`  | yes      | the schema (an object or a boolean)                          |
| `tests`   | yes      | array of `{"description": ..., "data": <instance>}`          |
| `remotes` | no       | map from absolute URI to a schema document, for `$ref`s      |

Exit status is 0 on success; on malformed input or an unresolvable reference
the error is printed to stderr and the status is 1.

## Library use

```clojure
(require '[jsonschema.core :as js]
         '[jsonschema.json :as json])

;; Schemas and instances are plain JSON data: nil, booleans, BigDecimals,
;; strings, vectors and string-keyed maps. json/parse produces them from text.
(def v (js/validator
        (json/parse "{\"type\": \"object\",
                      \"required\": [\"name\"],
                      \"properties\": {\"name\":  {\"type\": \"string\", \"minLength\": 1},
                                       \"price\": {\"type\": \"number\", \"multipleOf\": 0.01}},
                      \"unevaluatedProperties\": false}")))

(js/valid? v (json/parse "{\"name\": \"tea\", \"price\": 4.35}"))   ;=> true
(js/valid? v (json/parse "{\"name\": \"tea\", \"price\": 4.355}"))  ;=> false
(js/valid? v (json/parse "{\"name\": \"tea\", \"colour\": \"green\"}")) ;=> false

;; Remote documents, referenced by absolute URI:
(def v2 (js/validator (json/parse "{\"$ref\": \"http://example.test/int\"}")
                      {:remotes {"http://example.test/int" {"type" "integer"}}}))
(js/valid? v2 (json/parse "42")) ;=> true
```

A validator is immutable from the caller's point of view and can be reused for
any number of instances. Evaluation recurses with the nesting depth of the
schema and instance; for very deep input run it on a big stack:

```clojure
(js/with-large-stack (js/valid? v deeply-nested-instance))
```

### Namespaces

| namespace              | responsibility                                                         |
|------------------------|------------------------------------------------------------------------|
| `jsonschema.core`      | public API: `validator`, `valid?`, `with-large-stack`                  |
| `jsonschema.json`      | strict JSON parser to the data model (exact numbers)                   |
| `jsonschema.value`     | JSON equality and hashing, exact numeric helpers, `all-unique?`        |
| `jsonschema.regex`     | regex parser, NFA compiler and `search?`                               |
| `jsonschema.uri`       | RFC 3986 resolution, percent-decoding, RFC 6901 JSON Pointer           |
| `jsonschema.registry`  | schema index: resources, anchors, dynamic anchors, base URIs           |
| `jsonschema.keywords`  | per-keyword compilation to evaluator closures, annotations             |
| `jsonschema.schema`    | schema compiler, reference and dynamic-scope resolution                |
| `jsonschema.cli`       | the command-line tool                                                  |

## Tests

```sh
clojure -X:test
```

runs the unit and property tests (Cognitect test-runner, `clojure.test`,
`test.check`). `jsonschema.conformance-test` additionally runs the stdin-mode
conformance cases when they are available (`../problems/jsonschema/tests`, or
the directory in `$JSONSCHEMA_TESTS`) and is a no-op otherwise.

## Notes on semantics

* Numbers compare by exact value; `1`, `1.0` and `1e0` are the same number and
  `1.0` is an integer.
* String length is counted in code points.
* `pattern` / `patternProperties` are unanchored searches; `$` matches only at
  the very end of the string and `\b` is a boundary over `[A-Za-z0-9_]`.
* Unknown keywords (and `definitions`, `dependencies`, ...) are ignored,
  including any subschemas inside them.
* Supported regex syntax: alternation, groups, `* + ? {n,m}` (and lazy forms),
  `.`, `^`, `$`, `\b`, `\B`, classes, `\d \w \s` and their negations, and the
  usual character escapes. Property escapes, lookaround, named groups and
  backreferences are rejected.
