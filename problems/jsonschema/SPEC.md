# JSON Schema 2020-12 validator

Implement a validator for JSON Schema draft 2020-12. Read one JSON document
from stdin that holds a schema, an optional bundle of remote schema documents,
and a list of instances; print `valid` or `invalid` for each instance, one per
line.

The expected outputs are those of the official
[JSON-Schema-Test-Suite](https://github.com/json-schema-org/JSON-Schema-Test-Suite)
for draft 2020-12 (its `tests/draft2020-12/*.json`, excluding `optional/`),
plus real-world cases whose answers were cross-checked against the `jsonschema`
Python package. Sections 3–9 below are normative: they fix every point on which
two implementations could otherwise differ.

This is a library-sized problem. Expect roughly 2000–3500 lines: a JSON parser,
a small regular-expression engine, RFC 3986 reference resolution, a schema
index (`$id`/`$anchor`/`$dynamicAnchor`), and the keyword evaluator with
annotation collection.

Write the JSON parser, the regular-expression engine and the validator
yourself: don't use a JSON parser, a regex engine or a JSON Schema validator
from a library, the standard library or the language.

## 1. Input format (stdin)

Exactly one JSON value: an object with these members.

| member | required | meaning |
| --- | --- | --- |
| `schema` | yes | the schema to validate against — any JSON value (in practice an object or a boolean) |
| `tests` | yes | an array of objects, each with a `data` member (any JSON value) and a `description` string |
| `remotes` | no | an object mapping absolute URI strings to schema documents |

`description` is informational; ignore it. Additional members may be present
and must be ignored.

Guarantees about the input:

- It is UTF-8 and is valid JSON per RFC 8259. No object anywhere in the
  input has duplicate keys. Strings never contain unpaired surrogates.
- Every reference (`$ref`, `$dynamicRef`) reachable during validation resolves
  to a schema that is present in `schema` or in `remotes`. Nothing is fetched
  from the network.
- Every `pattern` and every `patternProperties` key is a regular expression
  inside the subset of section 8.
- Input size is at most 2 MB. Numbers have at most 400 significant digits and
  decimal exponents within ±400.

Example input:

```json
{
  "schema": {"type": "integer", "minimum": 1},
  "tests": [
    {"description": "a positive integer", "data": 3},
    {"description": "zero", "data": 0},
    {"description": "a string", "data": "3"}
  ]
}
```

## 2. Output format (stdout)

One line per element of `tests`, in order: `valid` if the instance satisfies
`schema`, `invalid` otherwise. Each line ends with `\n`. Nothing else is
printed. Exit status 0. For the example above:

```
valid
invalid
invalid
```

## 3. Data model

A JSON value is one of: null, boolean, **number**, string, array, object.

### 3.1 Numbers are exact decimals

A number literal `[-]digits[.digits][(e|E)[+|-]digits]` denotes the exact
rational `m x 10^e`, where `m` is the signed integer formed by the digits with
the decimal point removed and `e` is the literal exponent minus the number of
fractional digits. **All arithmetic and comparison on numbers is exact**;
binary floating point is not used anywhere. Implementations therefore need
arbitrary-precision integers (or an equivalent exact decimal type).

Two numbers are equal when they denote the same rational value, so `1`, `1.0`,
`1.00` and `1e0` are all the same number, and `100` equals `1e2`. A number is
an **integer** when it denotes a whole number, so `1.0`, `1e2` and `-0` are
integers and `1.5` is not.

This matters in two places. `multipleOf` is exact: `0.3` **is** a multiple of
`0.0001` here (it is `3000 x 0.0001`), although a validator using IEEE-754
doubles computes a quotient of `2999.9999999999995` and rejects it. The same
holds for `0.0021` and `0.0001`. Comparisons against bounds such as `1e308`
are likewise exact — `1e309` is simply a larger number, not an infinity.

### 3.2 Strings

A string is a sequence of Unicode code points. Its **length** is the number of
code points, not bytes and not UTF-16 units: `"💩"` (U+1F4A9) has
length 1, and `"é"` has length 2.

### 3.3 Objects and arrays

Objects are unordered maps from strings to values; iteration order never
affects the answer. Arrays are ordered and indexed from 0.

### 3.4 Equality

`enum`, `const` and `uniqueItems` use **JSON equality**, defined structurally:

- Values of different types are never equal. `true` is not `1`, `false` is not
  `0`, and `"1"` is not `1`.
- Numbers are equal when they denote the same rational (section 3.1).
- Strings are equal when they are the same code-point sequence.
- Arrays are equal when they have the same length and are element-wise equal.
- Objects are equal when they have the same set of keys and equal values under
  each key. Key order is irrelevant: `{"a":1,"b":2}` equals `{"b":2,"a":1}`.

## 4. Schemas, evaluation and annotations

A **schema** is either a boolean or an object. `true` accepts every instance;
`false` rejects every instance. A schema object accepts an instance when every
keyword it contains accepts that instance.

A keyword that does not apply to the instance's type is **inert**: it neither
accepts nor rejects and it produces no annotation. For example `maximum` is
inert for a string, and `required` is inert for an array. A keyword whose value
this specification does not define (any name listed neither in section 5 nor in
section 6, including `definitions`, `dependencies` and anything invented) is
inert as well — it is ignored, and so are any subschemas inside it. In
particular `$defs`, `title`,
`description`, `default`, `examples`, `deprecated`, `readOnly`, `writeOnly`,
`$comment`, `$vocabulary`, `contentEncoding`, `contentMediaType` and
`contentSchema` never affect the result, and `format` is an annotation only —
it never rejects anything (`{"type":"string","format":"ipv4"}` accepts
`"nope"`).

### 4.1 Annotations

Evaluating a schema against an instance yields, besides accept/reject, two
annotation sets used only by `unevaluatedItems` and `unevaluatedProperties`:

- **evaluated items** — a set of array indices, when the instance is an array;
- **evaluated properties** — a set of property names, when the instance is an
  object.

The sets produced by a schema object are the union of the sets produced by its
own keywords, and only when the schema object as a whole accepts the instance.
A schema object that rejects the instance produces empty sets. `true` and
`false` produce empty sets. Which keyword contributes what is given in
section 5; the rules that follow from it:

- Annotations cross `$ref` and `$dynamicRef`: the referenced schema's sets are
  the referencing keyword's sets.
- `allOf` contributes the union over all its subschemas (all of which accepted).
- `anyOf` contributes the union over the subschemas **that accepted**; the ones
  that rejected contribute nothing.
- `oneOf` contributes the sets of the single subschema that accepted.
- `if`/`then`/`else` contribute: the `if` subschema's sets when `if` accepted,
  plus the sets of whichever branch was applied.
- `not` contributes nothing, whatever the outcome.
- `propertyNames` contributes nothing (it applies to names, not values).
- `unevaluatedItems` and `unevaluatedProperties` themselves contribute the
  items and properties they successfully evaluated, so an outer
  `unevaluatedProperties` sees them as evaluated.

Annotations never escape a rejected branch and never flow between sibling
instances; they are collected per (schema object, instance) pair.

### 4.2 Evaluation order within a schema object

Within one schema object, evaluate every keyword except `unevaluatedItems` and
`unevaluatedProperties` first, in any order, collecting annotations from those
that accepted. If any of them rejected, the schema object rejects (with empty
annotation sets) and `unevaluatedItems`/`unevaluatedProperties` are not
applied. Otherwise apply `unevaluatedItems` (array instances) and
`unevaluatedProperties` (object instances) against the annotations collected so
far, as described in section 5.6.

Keywords are independent apart from the explicit couplings listed in section 5
(`prefixItems`→`items`, `properties`/`patternProperties`→`additionalProperties`,
`contains`→`min/maxContains`, `if`→`then`/`else`).

## 5. Keywords

Let `I` be the instance.

The count and bound keywords `maxLength`, `minLength`, `maxItems`, `minItems`,
`maxProperties`, `minProperties`, `maxContains` and `minContains` take a
non-negative integer, but it may be written in any numeric form that denotes
one: `2`, `2.0` and `2e0` are the same value, and all three forms occur in the
tests. Compare them as numbers (section 3.1), not as literals.

### 5.1 Any type

- **`type`**: a type name or an array of type names; accepts when `I`'s type is
  one of them. Names: `null`, `boolean`, `object`, `array`, `number`, `string`,
  `integer`. `integer` accepts a number that is an integer (section 3.1).
  `number` does not accept booleans.
- **`enum`**: an array; accepts when `I` is JSON-equal to one of its elements.
- **`const`**: accepts when `I` is JSON-equal to the value.

### 5.2 Numbers (inert unless `I` is a number)

- **`multipleOf`** (positive number): accepts when `I / value` is an integer,
  computed exactly. `0` is a multiple of everything.
- **`maximum`** / **`minimum`**: accepts when `I <= value` / `I >= value`.
- **`exclusiveMaximum`** / **`exclusiveMinimum`**: strict versions.

### 5.3 Strings (inert unless `I` is a string)

- **`maxLength`** / **`minLength`**: compare the code-point length (3.2).
- **`pattern`**: accepts when the regular expression **matches somewhere in**
  `I` (an unanchored search — `{"pattern":"bar"}` accepts `"foobarbaz"`). See
  section 8.

### 5.4 Arrays (inert unless `I` is an array)

- **`maxItems`** / **`minItems`**: compare `len(I)`.
- **`uniqueItems`**: when `true`, accepts when no two elements are JSON-equal.
  When `false`, accepts always.
- **`prefixItems`** (array of schemas): element `i` must satisfy schema `i`, for
  `i < min(len(prefixItems), len(I))`. Annotates those indices as evaluated.
- **`items`** (schema): applies to the elements from index
  `len(prefixItems)` onward (index 0 onward when there is no `prefixItems`
  array sibling). Annotates every index it applied to.
- **`contains`** (schema): let `H` be the set of indices whose element
  satisfies the schema. Accepts when `len(H) >= minContains` (default 1) and,
  if `maxContains` is present, `len(H) <= maxContains`. Annotates `H` as
  evaluated — note the whole set, not just the first match. With
  `minContains: 0` and no `maxContains`, `contains` always accepts (and still
  annotates `H`).
- **`minContains`** / **`maxContains`**: not keywords on their own; they only
  modify a sibling `contains`. Without a sibling `contains` they are inert.

### 5.5 Objects (inert unless `I` is an object)

- **`maxProperties`** / **`minProperties`**: compare the number of members.
- **`required`** (array of names): accepts when every name is a member of `I`.
- **`dependentRequired`** (name → array of names): for each name present in
  `I`, all the names it lists must also be present.
- **`properties`** (name → schema): each named member present in `I` must
  satisfy its schema. Annotates those names.
- **`patternProperties`** (pattern → schema): for each pattern, every member
  whose name the pattern **matches somewhere in** — the same unanchored search
  as `pattern` (5.3), applied to the member name — must satisfy that schema. A
  name may match several patterns and must then satisfy all of them.
  Annotates every name that matched at least one pattern.
- **`additionalProperties`** (schema): applies to every member whose name is
  neither a key of a sibling `properties` object nor matched by a key of a
  sibling `patternProperties` object. Annotates the names it applied to.
- **`propertyNames`** (schema): every member *name*, as a string instance, must
  satisfy the schema. Contributes no annotations.
- **`dependentSchemas`** (name → schema): for each name present in `I`, `I`
  must satisfy that schema. Contributes those schemas' annotations.

### 5.6 In-place applicators (any type)

- **`allOf`**, **`anyOf`**, **`oneOf`** (arrays of schemas): all must accept /
  at least one must accept / exactly one must accept.
- **`not`** (schema): accepts when the schema rejects.
- **`if`** / **`then`** / **`else`**: evaluate `if`. If it accepts, `I` must
  also satisfy `then` when `then` is present; otherwise `I` must satisfy `else`
  when `else` is present. `if` never causes rejection by itself. `then` and
  `else` without a sibling `if` are inert.
- **`unevaluatedItems`** (schema, array instances only): applies to every index
  of `I` not in the evaluated-items set collected per section 4.2; all must
  satisfy the schema. Annotates those indices.
- **`unevaluatedProperties`** (schema, object instances only): applies to every
  member of `I` whose name is not in the evaluated-properties set; all must
  satisfy the schema. Annotates those names.

## 6. Identifiers and references

### 6.1 Base URIs

Every schema object has a **base URI**. The root schema's base URI starts as
its *retrieval URI*: the empty string `""` for the schema under `schema`, and
the map key for each document under `remotes`.

When a schema object has a string `$id`, its base URI is `$id` **with any
fragment removed**, resolved against the base URI in force at that point using
RFC 3986 section 5.2.2 strict reference resolution (including
`remove_dot_segments`). That schema object becomes a new **schema resource**
whose base URI is that result, and the new base applies to it and everything
nested inside it until another `$id` appears. `$id` is only recognised in
positions that hold a schema (the keyword values listed in section 6.2); a
`$id` inside, say, a `const` value or an unknown keyword is data, not an
identifier.

Registration: a schema resource is registered under its base URI. A root
document is additionally registered under its retrieval URI when that URI is
not already taken. `$schema` is **not** a reference — it names a dialect, which
this problem fixes at 2020-12 — so it pulls nothing in and is ignored.

### 6.2 Where subschemas live

For indexing (`$id`, `$anchor`, `$dynamicAnchor`) and for base-URI propagation,
the subschemas of a schema object are exactly the values of:

- schema-valued keywords: `additionalProperties`, `propertyNames`, `items`,
  `contains`, `not`, `if`, `then`, `else`, `unevaluatedItems`,
  `unevaluatedProperties`, `contentSchema`;
- arrays of schemas: `allOf`, `anyOf`, `oneOf`, `prefixItems`;
- maps of schemas: `$defs`, `properties`, `patternProperties`,
  `dependentSchemas`.

`$defs` and `contentSchema` are indexed even though they are never applied.

### 6.3 Anchors

A string `$anchor` in a schema object registers that object under
`(base URI, name)`. A string `$dynamicAnchor` registers the object the same way
*and* marks `(base URI, name)` as a dynamic anchor. If both an `$anchor` and a
`$dynamicAnchor` with the same name exist under one base, the `$anchor` wins
for plain lookups.

### 6.4 `$ref`

`$ref` is a URI reference. Resolve it against the base URI of the schema object
that contains it, then split the result into a document part and a fragment.
Percent-decode the fragment (as UTF-8) before interpreting it.

- Empty fragment: the target is the schema resource registered under the
  document part.
- Fragment starting with `/`: a JSON Pointer (RFC 6901 — `~1` means `/`, `~0`
  means `~`) evaluated from the schema resource registered under the document
  part. In these inputs such a pointer always lands on a position that holds a
  schema in the sense of section 6.2 — `$defs` entries included — so the base
  URI in force at the target is the one the indexing walk of section 6.2
  recorded for it.
- Any other fragment: a plain-name anchor; the target is the schema registered
  under `(document part, fragment)`.

Validation continues in the target schema; its own base URI (from its
enclosing `$id`) governs references inside it. `$ref` has no special
precedence: sibling keywords of a `$ref` are evaluated too, and all of them
must accept.

### 6.5 `$dynamicRef` and the dynamic scope

The **dynamic scope** is the sequence of base URIs entered while validating,
outermost first: each time evaluation moves into a schema object whose base URI
differs from the innermost one currently on the scope, that base is pushed.

To resolve `$dynamicRef`: resolve it against the containing schema's base URI
and split off the fragment (percent-decoded). If the fragment is a plain name
(not empty, not starting with `/`) **and** that name is a dynamic anchor under
the resolved document part, then walk the dynamic scope from the outermost
entry inward and use the first base URI under which that name is a dynamic
anchor. Otherwise `$dynamicRef` behaves exactly like `$ref`.

This is what makes a generic schema extensible:

```json
{
  "$id": "https://example.test/strings",
  "$defs": {
    "itemType": {"$dynamicAnchor": "itemType", "type": "string"},
    "list": {
      "$id": "https://example.test/list",
      "$defs": {"itemType": {"$dynamicAnchor": "itemType"}},
      "type": "array",
      "items": {"$dynamicRef": "#itemType"}
    }
  },
  "$ref": "https://example.test/list"
}
```

`["a","b"]` is valid and `["a",1]` is invalid: the `$dynamicRef` inside the
generic list resolves to the *outermost* `itemType` in the dynamic scope, which
is the string-typed one, rather than to the empty one beside it.

### 6.6 Remotes

`remotes` supplies every document the schema refers to by absolute URI —
the JSON-Schema-Test-Suite documents normally served from
`http://localhost:1234/`, and, where a test needs them, the nine published
2020-12 meta-schema documents (`https://json-schema.org/draft/2020-12/schema`
and its `meta/*` vocabulary schemas). Index each of them exactly as described
above, using its map key as the retrieval URI. Documents that are never
referenced are simply unused.

## 7. Worked examples

### 7.1 Annotations and `unevaluatedProperties`

```json
{"schema": {"allOf": [{"properties": {"a": {"type": "integer"}}},
                      {"properties": {"b": {"type": "integer"}}}],
            "if": {"required": ["a"]},
            "then": {"properties": {"c": {"type": "string"}}},
            "unevaluatedProperties": false},
 "tests": [{"data": {"a": 1, "b": 2}},
           {"data": {"a": 1, "c": "yes"}},
           {"data": {"b": 2, "c": "yes"}},
           {"data": {"a": 1, "d": 0}}]}
```

Output:

```
valid
valid
invalid
invalid
```

`a` and `b` are evaluated by the `allOf` branches. `c` is evaluated only when
the `then` branch applies, which needs `a`; in the third instance `a` is
absent, so `if` fails, `else` is absent, `c` stays unevaluated and
`unevaluatedProperties: false` rejects it. `d` is never evaluated by anything.

### 7.2 `contains` with counts

`{"type":"array","contains":{"type":"integer"},"minContains":2,"maxContains":3}`
accepts `[1,"a",2]` and `["a",1,2,3,"b"]`, rejects `[1,"a"]` (one match) and
`[1,2,3,4]` (four matches).

### 7.3 Type-aware equality

`{"enum":[1,"1",null,[1],{"a":1}]}` accepts `1`, `1.0` and `{"a":1.000}`; it
rejects `true` (a boolean is not the number 1), `false` and `[2]`.

### 7.4 Base URI changes and relative references

```json
{"schema": {"$id": "http://localhost:1234/draft2020-12/root-of-its-own.json",
            "type": "object",
            "properties": {"i": {"$ref": "integer.json"},
                           "n": {"$ref": "subSchemas.json#/$defs/integer"}}},
 "remotes": {"http://localhost:1234/draft2020-12/integer.json": {"type": "integer"},
             "http://localhost:1234/draft2020-12/subSchemas.json":
                 {"$defs": {"integer": {"type": "integer"}}}},
 "tests": [{"data": {"i": 1, "n": 2}}, {"data": {"i": "1"}}]}
```

Output: `valid` then `invalid`. Both references are relative to the `$id`, so
they resolve under `http://localhost:1234/draft2020-12/`.

## 8. Regular expressions

`pattern` and the keys of `patternProperties` are ECMA-262 regular expressions
used for **membership only**: the question is always "does this pattern match
anywhere in this string", never where or what was captured. Matching is over
Unicode code points and there are no flags (no `i`, no `m`, no `s`).

This is the subset of `problems/regex/SPEC.md` section 2 extended as listed
below; the matching semantics there (ordered choice, greedy quantifiers,
backtracking) still describe *how* a match is found, but since only a yes/no
answer is reported, any correct matcher will do. Unlike that problem, matching
here is over Unicode rather than ASCII, and a pattern is searched for at every
start position rather than anchored.

Guaranteed constructs — an implementation must support all of these, and test
inputs use nothing else:

- alternation `|`, concatenation, and grouping with `( ... )` or `(?: ... )`.
  Both forms are plain grouping here; backreferences never appear.
- quantifiers `*`, `+`, `?`, `{n}`, `{n,}`, `{n,m}`, each optionally followed by
  `?` for the lazy form. A `{` that does not begin a well-formed quantifier is a
  literal `{`.
- `.` matches any code point except the line terminators U+000A, U+000D,
  U+2028 and U+2029.
- `^` matches only at position 0, `$` only at the end of the string. `\b` and
  `\B` are word boundaries over `[A-Za-z0-9_]`.
- character classes `[...]` and `[^...]` containing single characters, ranges
  `x-y` (by code point) and the class escapes below. `-` is literal when it is
  first, last, or escaped.
- class escapes `\d` `[0-9]`, `\D`, `\w` `[A-Za-z0-9_]`, `\W`, `\s` (U+0009–
  U+000D, U+0020, U+00A0, U+1680, U+2000–U+200A, U+2028, U+2029, U+202F,
  U+205F, U+3000, U+FEFF), `\S`. They are usable inside and outside classes.
- character escapes `\n` `\r` `\t` `\f` `\v` `\0`, `\xHH`, `\uHHHH` (a
  surrogate pair `💩` denotes the astral code point),
  `\cX` (control letter), and a backslash before any non-alphanumeric character,
  which means that character literally (`\.`, `\\`, `\*`, `\[`, `\/`, `\-`, ...).
  Inside a class, `\b` means backspace U+0008.

Not required, and never present in a test input: Unicode property escapes
`\p{...}` / `\P{...}`, lookahead and lookbehind, named groups, backreferences,
and the `u`/`v`-mode-only syntax, `\u{...}` included. (The two schema groups of
the official suite that use `\p{...}` are excluded from this problem's tests for
that reason.)

## 9. Divergences from other validators

Three decisions are fixed here that some implementations make differently. Each
is what the official suite expects wherever it has an opinion.

1. **Exact decimal arithmetic** (section 3.1). Validators that use doubles
   reject `0.3` against `{"multipleOf": 0.0001}`; this specification accepts it.
2. **`$vocabulary` is ignored.** It never switches a vocabulary off, so the
   validation keywords always assert. (The one suite group that depends on
   `$vocabulary` disabling a keyword is excluded from this problem's tests.)
3. **The regular-expression semantics of section 8 are ECMA-262's**, not those
   of a host regex library. Two consequences are pinned by the tests: `\b` is a
   boundary over `[A-Za-z0-9_]` only, so `\bcat\b` matches inside `"écat "`;
   and `$` matches only at the very end of the string, so `^a$` does not match
   `"a\n"`. Validators built on many host regex libraries answer both the
   other way. The
   expected outputs here are the ECMA-262 ones, cross-checked against a
   JavaScript engine.

`format` is annotation-only, as draft 2020-12 specifies by default, so
`format` never rejects.

## 10. Suggested architecture

1. **JSON parser** — produces the data model of section 3, keeping each number
   as an exact mantissa/exponent pair taken from the literal. Do not route
   numbers through a binary float.
2. **Regex engine** — a parser for section 8 producing a syntax tree, and a
   backtracking matcher answering "matches anywhere?". Cache compiled patterns;
   several tests apply one `patternProperties` key to many member names.
3. **URI machinery** — RFC 3986 split/merge/`remove_dot_segments`/recompose, and
   RFC 6901 JSON Pointer evaluation with percent-decoding of fragments.
4. **Schema index** — one walk over every document (section 6.2) recording, for
   each schema object, its base URI, and filling maps from base URI to resource
   root and from `(base, name)` to anchor target, plus the set of dynamic
   anchors.
5. **Evaluator** — one function taking (schema, instance, dynamic scope) and
   returning accept/reject plus the two annotation sets, dispatching over the
   keywords of section 5 and applying `unevaluated*` last.

Recursion can be deep — the meta-schema validating the OpenAPI 3.1 schema
nests hundreds of levels — so raise the stack limit or use an explicit stack.

## 11. Tests

`tests/001_*` to `tests/025_*` are hand-written cases, one rule each, matching
the worked examples above. `tests/026_*` to `tests/406_*` are the official
suite, one file per schema group, in the keyword order given in `gen_tests.py`;
their expected outputs are the suite's published `valid` flags. `tests/407_*`
onward are real-world cases: the OpenAPI 3.1 document schema over published
OpenAPI documents, the SchemaStore `package.json` schema over published npm
manifests, and the 2020-12 meta-schema over published schemas (including
itself). Corpus provenance and licensing are recorded in `corpus/SOURCES.md`.
