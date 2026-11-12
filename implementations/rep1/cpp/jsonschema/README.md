# jsonschema

A self-contained C++17 validator for [JSON Schema draft 2020-12](https://json-schema.org/draft/2020-12),
with a reusable library and a small command-line tool. It has no dependencies beyond the standard
library (GoogleTest is needed only for the unit tests).

Everything is written from scratch: the JSON parser, an exact decimal number type, a regular-expression
engine, RFC 3986 reference resolution, the schema index and the evaluator.

Highlights:

- **Exact numbers.** JSON numbers are exact decimals, never doubles: `0.3` is a multiple of `0.0001`,
  `1e309` is just a large number, `1.0` equals `1`.
- **Linear-ish regex.** `pattern` / `patternProperties` use an NFA simulation, O(P·L) per test, with no
  catastrophic backtracking. Semantics follow ECMA-262 (`\b` is ASCII-only, `$` matches only at the end).
- **Full reference support.** `$id`, `$anchor`, `$dynamicAnchor`, `$ref`, `$dynamicRef` (with the dynamic
  scope), JSON-pointer fragments, and caller-supplied "remote" documents (nothing is ever fetched).
- **Annotations.** `unevaluatedItems` / `unevaluatedProperties` see the items and properties evaluated by
  in-place applicators, `$ref`s, `contains`, `if`/`then`/`else`, and so on. Annotations are only collected
  when a schema actually uses an `unevaluated*` keyword.
- `format` is annotation-only; `$vocabulary` is ignored; `$schema` is ignored.

## Layout

| path | contents |
| --- | --- |
| `include/jsonschema/` | public headers |
| `src/` | implementation (`compiler.cpp`, `evaluator.cpp`, ... and the private `schema_internal.hpp`) |
| `cli/main.cpp` | the command-line tool |
| `tests/` | GoogleTest unit tests |

Library modules:

| header | responsibility |
| --- | --- |
| `utf8.hpp` | code-point length, decoding, encoding |
| `decimal.hpp` | `Decimal`: exact comparison, integer test and `multipleOf` |
| `json.hpp` | `Value`, `parse_json`, JSON equality and hashing |
| `regex.hpp` | `Regex`: compiled ECMA-262-subset pattern with `search()` |
| `uri.hpp` | RFC 3986 resolution, fragments, RFC 6901 pointers |
| `schema.hpp` | `Schema`: compile once, validate many instances |

## Build

Requires a C++17 compiler and CMake ≥ 3.20. GoogleTest is optional (found with `find_package(GTest)`).

```sh
./build.sh            # Release build into ./build
# or, by hand:
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build   # run the unit tests
```

Pass `-DJSONSCHEMA_BUILD_TESTS=OFF` to skip the tests. To use the library from another CMake project,
`add_subdirectory(jsonschema)` and link against `jsonschema::jsonschema`.

## Command-line tool

`run.sh` (or `build/jsonschema-cli`) reads one JSON document on stdin:

```json
{
  "schema":  {"type": "integer", "minimum": 1},
  "tests":   [{"description": "a positive integer", "data": 3},
              {"description": "zero", "data": 0},
              {"description": "a string", "data": "3"}],
  "remotes": {"http://example.test/other.json": {"type": "string"}}
}
```

- `schema` (required): the root schema (retrieval URI `""`).
- `tests` (required): instances to check; only `data` is used, `description` is informational.
- `remotes` (optional): absolute URI → schema document, available to `$ref` / `$dynamicRef`.

It prints `valid` or `invalid`, one line per test, in order:

```
$ ./run.sh < input.json
valid
invalid
invalid
```

Exit status is 0 on success. Malformed input, an invalid `pattern`, or a `$ref` that cannot be resolved
when it is reached produce a message on stderr and exit status 1. The tool runs on a thread with a large
stack so that deeply nested schemas (e.g. the OpenAPI 3.1 meta-schema) are fine.

## Library example

```cpp
#include <iostream>
#include "jsonschema/schema.hpp"

int main() {
  using namespace jsonschema;

  Schema schema = Schema::compile_json(R"({
    "$id": "https://example.test/person",
    "type": "object",
    "properties": {
      "name": {"type": "string", "minLength": 1},
      "age":  {"type": "integer", "minimum": 0},
      "tags": {"type": "array", "items": {"type": "string"}, "uniqueItems": true}
    },
    "required": ["name"],
    "unevaluatedProperties": false
  })");

  std::cout << schema.is_valid(parse_json(R"({"name": "Ada", "age": 36})")) << "\n";  // 1
  std::cout << schema.is_valid(parse_json(R"({"age": 36})")) << "\n";                 // 0 (name missing)
  std::cout << schema.is_valid(parse_json(R"({"name": "Ada", "x": 1})")) << "\n";     // 0 (unevaluated)

  // Documents referenced by absolute URI are supplied up front.
  std::vector<Remote> remotes;
  remotes.emplace_back("https://example.test/positive", parse_json(R"({"type":"number","exclusiveMinimum":0})"));
  Schema with_ref = Schema::compile(parse_json(R"({"$ref": "https://example.test/positive"})"), std::move(remotes));
  std::cout << with_ref.is_valid(parse_json("0.0001")) << "\n";  // 1
}
```

Link with `jsonschema::jsonschema`. The lower-level pieces are usable on their own:

```cpp
Regex::compile("^[a-z]+\\d*$").search("abc123");               // true
Decimal::parse("0.3")->is_multiple_of(*Decimal::parse("0.0001")); // true
uri::resolve("../x.json", "http://a/b/c/d.json");              // "http://a/b/x.json"
```

### Notes on the API

- `Schema::compile` throws `SchemaError` for a pattern outside the supported syntax. References are resolved
  during compilation, but an unresolvable one is only reported (as `SchemaError` from `is_valid`) if
  evaluation reaches it.
- A compiled `Schema` is immutable; `is_valid` is `const` and safe to call from several threads.
- Evaluation recurses, so extremely deep schemas/instances need a large stack (the CLI provides one).

## Supported regular-expression syntax

Alternation, `(...)` / `(?:...)` grouping, `* + ? {n} {n,} {n,m}` (and lazy forms), `.`, `^`, `$`, `\b`,
`\B`, classes with ranges, `\d \D \w \W \s \S`, and the escapes `\n \r \t \f \v \0 \xHH \uHHHH \cX` plus
escaped punctuation. Not supported: lookaround, backreferences, named groups, `\p{...}`, flags.
