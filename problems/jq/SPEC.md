# jq — a jq-subset query language

Implement an interpreter for a subset of the `jq` filter language. Read one
filter and one JSON document from stdin, evaluate the filter against the
document, and print every result as compact JSON, one per line. The
semantics below are those of jq 1.7 (`jq -c`), restricted to the subset
described here; every expected output in the test suite was produced by, and
cross-checked against, jq 1.7.1.

Write the JSON parser, the JSON serializer and the filter interpreter yourself:
don't use a JSON library or a jq implementation from a library, the standard
library or the language.

## Input

- Line 1 (up to the first `\n`) is the **filter**, in the syntax below. It is
  at most 2000 bytes and always syntactically valid within the subset
  (you never have to report a parse error).
- Everything after that first newline is the **input document**: exactly one
  JSON value (any type, possibly spanning many lines, possibly with
  surrounding whitespace), valid per RFC 8259. The document is at most 6 MB.
  Parse it with your own JSON parser (no JSON library), as follows:
  - Whitespace between tokens is any run of space, tab, LF and CR; nothing
    else is whitespace.
  - Strings decode the escapes `\" \\ \/ \b \f \n \r \t` and `\uXXXX`
    (hex digits in either case). A `\uXXXX` high surrogate (D800–DBFF)
    followed by a `\uXXXX` low surrogate (DC00–DFFF) is one code point
    (`\ud83d\ude00` is U+1F600). Every other byte of a string, including
    multi-byte UTF-8 sequences, is taken as is.
  - A number is the IEEE-754 double nearest to its decimal value (correct
    rounding, ties to even, as C's `strtod` gives). Integers and decimals are
    both doubles; there is no separate integer type.
  - Objects keep their members in document order (see *Objects and key
    order* below).
- Input is UTF-8. Objects in the document never contain duplicate keys.
  Strings (in the document and in the filter) never contain U+0000, and
  `\uXXXX` escapes never form an unpaired surrogate.
- Every number literal in the document and in the filter is already written
  in the canonical output form described below (so `1.0`, `2.50`, `007`,
  `1e2` and `-0` never occur): `.` reproduces the document's numbers
  byte for byte.

## Output

- Each result of the filter is printed as one line of **compact JSON**
  (no spaces anywhere), terminated by `\n`, in the order the filter produces
  them.
- If evaluation raises an error that is not caught by `?`, print every result
  produced *before* the error (in order), then one line containing exactly
  `error`, and stop. Nothing is printed after `error`.
- A filter that produces no results prints nothing.
- Exit code 0 always. stderr is ignored.

### JSON formatting

- `null`, `true`, `false`; arrays `[a,b]`; objects `{"k":v,"k2":v2}`.
- **Object key order** is the object's insertion order (see *Objects and key
  order* below), never sorted.
- **Strings**: `"` → `\"`, `\` → `\\`, U+0008 `\b`, U+000C `\f`, U+000A
  `\n`, U+000D `\r`, U+0009 `\t`, every other code point below U+0020 as
  `\u00XX` with lowercase hex, and U+007F as `\u007f`. Everything else
  (including `/`, `<`, `>`, `&`, and all non-ASCII code points) is emitted
  raw as UTF-8.
- **Numbers**: all numbers are IEEE-754 doubles. A number whose value is an
  integer prints as that integer with no decimal point or exponent
  (`3`, `-12`, `1000000000000`). Any other number prints in the shortest
  decimal form that round-trips to the same double (`1.5`, `0.125`,
  `3086419725308.5`). Tests are constructed so that no output number ever
  needs more than this: every non-integral number that appears in an expected
  output has at most 15 significant digits, magnitude in `[0.001, 1e15)`, and
  prints as plain `-?ddd.ddd` with no trailing zeros; every integral number
  has magnitude below 2^53. Consequently printing non-integers with
  `%.15g` and stripping trailing zeros gives the correct text for every test.
  NaN and infinities never occur. Negative zero never appears in an output
  (the reference would print it as `-0`, as jq does); it can arise as an
  intermediate value (e.g. `sort_by(-.n)` on an element with `n` equal to
  `0`), where it simply compares equal to `0`.

## Data model

Values are `null`, `false`, `true`, numbers (doubles), strings (sequences of
Unicode code points), arrays, and objects (string-keyed, insertion-ordered
maps). All numbers in the input document and in filters are integers of
magnitude below 2^53 or decimals with at most 15 significant digits; the
filter never uses exponent notation.

**Truthiness**: `false` and `null` are false; everything else (including
`0`, `""`, `[]`, `{}`) is true.

**Ordering** (used by `sort`, `sort_by`, `group_by`, `unique`, `min`, `max`,
`<`, `<=`, `>`, `>=`): a total order. First by type:
`null < false < true < numbers < strings < arrays < objects`. Within a type:
numbers numerically; strings by code point sequence (equivalently, by UTF-8
bytes; `"" < "a" < "ab" < "b"`, `"Z" < "a"`, `"z" < "é"`); arrays
lexicographically element by element, a proper prefix sorting first;
objects first by their *sorted* key lists compared as arrays of strings, then,
if those are equal, by the values of each key in sorted key order.
**Equality** (`==`, `!=`, `unique`, `group_by`, array subtraction) is
"compares equal under this order"; key order of objects is irrelevant to
equality, and integers and non-integers are one numeric type
(`1 == (1.5 - 0.5)` is `true`).

### Objects and key order

An object remembers the order in which its keys were first inserted, and
prints in that order. Rules:
- The input document's objects keep the key order of the document text.
- Object construction `{...}` inserts keys left to right; a repeated key
  keeps its first position but takes the last value (`{a:1,b:2,a:3}` →
  `{"a":3,"b":2}`).
- `a + b` on objects is `a` with each key of `b` set in order: existing keys
  keep their position (value replaced), new keys are appended
  (`{"z":1,"a":2} + {"m":3,"z":9}` → `{"z":9,"a":2,"m":3}`).
- `a * b` on objects is the same but recursive: when both values under a key
  are objects they are merged recursively; otherwise `b`'s value wins.
- `keys` returns keys sorted by code point, not insertion order.
- Nothing else reorders or mutates an object; values are immutable, every
  operation returns a new value.

## Filter syntax

Whitespace (space, tab) separates tokens and is otherwise insignificant.
Identifiers are `[A-Za-z_][A-Za-z0-9_]*`. Keywords: `if then elif else end
as reduce and or true false null`; tests never use keywords as bare field
names or object keys. Number literals are `[0-9]+(\.[0-9]+)?`. String
literals are double-quoted with JSON escapes (`\" \\ \/ \b \f \n \r \t
\uXXXX`, surrogate pairs allowed); there is no string interpolation.
Variables are `$name`. Number literals are canonical: no leading zeros
(other than a lone `0`), no trailing zeros after the point (`1.0` never
occurs; `1.5`, `0.25`, `100` do).

Grammar (`{x}` = zero or more, `[x]` = optional):

```
pipe     := postfix "as" "$" IDENT "|" pipe          -- variable binding
          | comma [ "|" pipe ]                        -- "|" is right-assoc
comma    := or { "," or }
or       := and { "or" and }
and      := cmp { "and" cmp }
cmp      := add [ ("==" | "!=" | "<" | "<=" | ">" | ">=") add ]   -- non-assoc
add      := mul { ("+" | "-") mul }
mul      := unary { ("*" | "/" | "%") unary }
unary    := "-" unary | postfix
postfix  := primary { suffix }
suffix   := "." IDENT                -- field:   .foo
          | "." STRING               -- field:   ."foo bar"
          | "[" pipe "]"             -- index:   [e]
          | "[" "]"                  -- iterate: []
          | "[" [pipe] ":" [pipe] "]"-- slice:   [a:b]  [:b]  [a:]
          | "?"                      -- optional / try
primary  := "."                      -- identity
          | "." IDENT | "." STRING   -- field access on the input
          | NUMBER | STRING | "true" | "false" | "null"
          | "$" IDENT
          | "(" pipe ")"
          | "[" [pipe] "]"           -- array construction
          | "{" [entry {"," entry}] "}"
          | "if" pipe "then" pipe {"elif" pipe "then" pipe} ["else" pipe] "end"
          | "reduce" postfix "as" "$" IDENT "(" pipe ";" pipe ")"
          | IDENT [ "(" pipe { ";" pipe } ")" ]     -- builtin call
entry    := IDENT ":" objval | STRING ":" objval | "(" pipe ")" ":" objval
          | IDENT                    -- {a}   means {a: .a}
          | STRING                   -- {"a"} means {"a": .a}
          | "$" IDENT                -- {$x}  means {x: $x}
objval   := objterm { "|" objterm }
objterm  := "-" objterm | postfix
```

Notes on the grammar:
- Precedence from loosest to tightest: `|`, `,`, `or`, `and`, comparisons,
  `+ -`, `* / %`, unary `-`, postfix suffixes. `a | b, c` is `a | (b, c)`;
  `1, 2 | f` is `(1, 2) | f`. Comparisons do not chain.
- A `pipe`, hence a binding `E as $x | body`, occurs at top level, inside
  `( )`, `[ ]`, the parts of `if`, the parenthesised parts of `reduce`, the
  `[e]`/`[a:b]` brackets, and builtin arguments. The body of a binding
  extends as far right as possible (to the end of the enclosing pipe). In
  tests the source `E` of `as` is always a postfix term, and a binding never
  appears as the right operand of `,` or of an arithmetic operator.
- Object values (`objval`) are restricted as in jq: a postfix term, a
  pipeline of postfix terms, or a negated one. Anything else (e.g. `1 + 2`)
  must be parenthesised. Object keys given as `IDENT` or `STRING` are literal
  strings; `(pipe)` keys are computed.
- Unary `-` applies to the following unary/postfix term; `-1`, `-.a`,
  `-(.a + 1)`, `2 * -3`, `1 - -1` all appear. `1 -1` is subtraction.
- `?` binds to the postfix term to its left; see *Optional* below for its two
  meanings.

## Evaluation model

A filter is a function from one input value to a **stream** of zero or more
output values. `.` is the input. Evaluation is lazy and ordered: outputs are
produced in the order given below, and an error aborts the whole evaluation
at the point it occurs (results already produced before it are still
printed). When a construct combines several streams, the loop nesting below
defines the order exactly.

- `f | g`: for each output `v` of `f` (in order), all outputs of `g` with
  input `v`.
- `f, g`: all outputs of `f`, then all outputs of `g` (same input).
- `f op g` for `+ - * / %` and comparisons: **the right operand is the outer
  loop**: for each output `b` of `g`, for each output `a` of `f`, yield
  `a op b`. So `[(1,2) + (10,20)]` is `[11,12,21,22]`.
- `f and g`: for each `a` of `f`: if `a` is false, yield `false`; otherwise
  for each `b` of `g` yield the truthiness of `b`. `f or g` symmetrically
  (`a` true → yield `true`, else the truthiness of each `b`). `g` is not
  evaluated when short-circuited (`false and error` is `false`).
- `-f`: for each output, negate; error unless it is a number.
- `[f]`: collect all outputs of `f` into one array (one output; `[]` for
  none). If `f` errors, the whole construct errors.
- `{k1: v1, k2: v2, ...}`: entries left to right, nested loops with the first
  entry outermost; within an entry the key stream is outer and the value
  stream inner. Each combination yields one object. Computed keys must be
  strings, otherwise error. `{a:(1,2), b:(3,4)}` yields `{"a":1,"b":3}`,
  `{"a":1,"b":4}`, `{"a":2,"b":3}`, `{"a":2,"b":4}`.
- `if c then a elif c2 then b else d end`: for each output of `c`: if true,
  all outputs of `a`, else the outputs of the rest of the chain (`elif` is a
  nested `if`). Without `else`, the else branch is `.`.
- `E as $x | body`: for each output `v` of `E` (evaluated on the input),
  all outputs of `body` on the **same input** with `$x` bound to `v`. Inner
  bindings shadow outer ones. `$x` inside `body` yields the bound value.
- `reduce SRC as $x (INIT; UPDATE)`: for each output `init` of `INIT`
  (evaluated on the input): set `acc = init`; for each output `v` of `SRC`
  (evaluated on the input): evaluate `UPDATE` with input `acc` and `$x = v`,
  and set `acc` to its **last** output (or `null` if it produced none);
  finally yield `acc`.
- Literals yield themselves. `empty` yields nothing. `error` raises an
  error; `error(f)` raises an error for the first output of `f` (and raises
  nothing if `f` is empty).

### Paths: field, index, iterate, slice

Each suffix applies to every output of the term before it.

- `.foo`, `."foo"`, `.[k]` with a **string** `k`: on an object, the value of
  that key or `null` if absent; on `null`, `null`; on anything else, error.
- `.[k]` with a **number** `k`: on an array, the element at index `k`
  (negative `k` counts from the end: `-1` is the last element); `null` if out
  of range; on `null`, `null`; on anything else, error. Indices in tests are
  always integers (a non-integer `k` would be truncated toward zero first).
- `.[k]` with any other kind of `k` (including `null`): error, even on
  `null`.
- Generator order for `T[K]`: for each output `k` of `K`, for each output `t`
  of `T`, yield `t[k]`. (`([1,2],[3,4])[(0,1)]` → `1, 3, 2, 4`.)
- `.[]`: on an array, each element in order; on an object, each value in
  insertion (key) order; on anything else (including `null`), error.
- `.[a:b]`, `.[:b]`, `.[a:]`: on an array or string (by code points), the
  elements/characters from `a` (default 0) up to but excluding `b`
  (default length). Negative bounds have the length added; then both are
  clamped to `[0, length]` and `b` is raised to `a` if smaller. On `null`,
  `null`. On anything else, error. Bounds must be numbers (integers in
  tests). Generator order: for each `a`, for each `b`, for each output of the
  term.

### Optional (`?`)

`?` has two meanings depending on what precedes it:

1. Directly after a field/index/iterate/slice suffix (`.a?`, `.[0]?`,
   `.[]?`, `.[1:]?`, `."k"?`), it makes **that one operation** tolerant: for
   each (index, target) combination, if that operation itself would error,
   that combination is skipped and evaluation continues with the next one.
   Errors raised while computing the index expression or the target itself
   are *not* suppressed. So on input `5`, `.a?` is empty but `.a.b?` is an
   error (the error is in `.a`, not in `.b`), while `[([1],2,[3])[0]?]` is
   `[1,3]` and `[(1,[2],3)[]?]` is `[2]`.
2. After anything else — a parenthesised expression, a builtin call, a
   literal, a variable, or a term that already ends in `?` — it is `try`:
   the term's outputs are produced until the first error, which is then
   swallowed and the term stops. `[(1,2,error,3)?]` is `[1,2]`;
   `(.a.b)?` on `5` is empty; `[.[] | tonumber?]` skips unparsable
   elements.

In both cases only errors raised *inside* the marked term are caught; errors
raised later in the pipeline on values it produced propagate normally
(`(1,2)? | error` is an error).

### Arithmetic

Type combinations not listed are errors.

- `+`: `null + x = x`, `x + null = x` (any `x`); number + number; string +
  string (concatenation); array + array (concatenation); object + object
  (shallow merge, right wins, see key order rules).
- `-`: number − number; array − array: the elements of the left array that
  are not equal to any element of the right array (order kept, all
  occurrences removed).
- `*`: number × number; string × number **or** number × string: if the
  number is negative the result is `null`, otherwise the string repeated
  `n` times where `n` is the number truncated to an integer (`0` gives
  `""`); object × object: recursive merge.
- `/`: number ÷ number, error if the divisor is `0`; string ÷ string: split
  the left string on the right string, giving an array (`"a,b,,c" / ","` →
  `["a","b","","c"]`; `"" / ","` → `[]`; `"abc" / ""` → `["a","b","c"]`).
  Division in tests always yields a number satisfying the printing
  restrictions above.
- `%`: number % number: both operands are truncated toward zero to
  integers; if the divisor becomes `0`, error; otherwise the remainder with
  the sign of the dividend (C semantics): `-7 % 3 = -1`, `7 % -3 = 1`,
  `5.5 % 2 = 1`, `5 % 0.5` is an error.
- Comparisons `== != < <= > >=` never error; they use the ordering above.

### Builtins

| Builtin | Behaviour |
|---|---|
| `empty` | no outputs |
| `error` | error (message is the input; irrelevant to output) |
| `error(f)` | error for the first output of `f`, whatever that output is (`error(null)` is an error too); no outputs if `f` is empty |
| `not` | `true` if the input is false/null, else `false` |
| `length` | `null` → `0`; number → absolute value; string → number of code points; array/object → element/key count; boolean → error |
| `keys` | object → its keys sorted by code point, as an array; array → `[0,1,...,n-1]`; anything else → error |
| `has(k)` | for each output `k`: object with string `k` → whether the key exists; array with number `k` → whether `0 <= i < length` where `i` is `k` truncated toward zero (`has(1.5)` on `[1,2]` is `true`, `has(-1)` is `false`); `null` input → `false` whatever `k` is; any other combination → error |
| `type` | `"null"`, `"boolean"`, `"number"`, `"string"`, `"array"`, `"object"` |
| `add` | `reduce .[] as $x (null; . + $x)`: sums the elements of an array (or the values of an object) with `+` starting from `null`; `[]` → `null`; non-iterable input or incompatible elements → error |
| `select(f)` | for each output of `f` that is true, yield the input |
| `map(f)` | `[.[] \| f]` (works on arrays and objects; error otherwise) |
| `sort` | array sorted by the ordering above (stable); non-array → error |
| `sort_by(f)` | array sorted by the key `[f]` (the array of **all** outputs of `f` on each element, so `sort_by(.a, .b)` sorts by `.a` then `.b`), stable; non-array → error |
| `group_by(f)` | array of arrays: elements grouped by equal `[f]` key, groups in ascending key order, each group in original order; non-array → error |
| `unique` | `sort` then drop elements equal to the previous one, keeping the first of each run |
| `reverse` | array → reversed copy; `null` → `[]`; string, boolean, object → error (tests never apply it to a number) |
| `min` / `max` | of an array: the least / greatest element; on ties `min` returns the **first** minimal and `max` the **last** maximal element (this matters only for equal-but-differently-ordered objects); `[]` → `null`; non-array → error |
| `tostring` | string → itself; anything else → its compact JSON text (same formatting rules as output) |
| `tonumber` | number → itself; string that is a JSON number → that number; anything else (other types, non-numeric strings, `""`) → error. Tests only use strings that are canonical numbers exactly as the output rules would print them (`"12"`, `"-2.5"`, `"3.25"`, `"0"`; never `"1.0"`, `"007"`, `"-0"`, `" 1"`) for success, and strings containing letters or empty strings for failure |

Unknown builtins do not occur in tests.

## Limits

- Filter ≤ 2000 bytes; document ≤ 6 MB (the largest tests are ~5 MB with
  ~25,000 records); nesting depth ≤ 64.
- Up to ~25,000 output lines in one test.
- No single test needs more than a few seconds in the reference
  implementation (written in Python)
  (the long benchmark tier needs up to about 15 minutes per input).

## Examples

### Example 1

Input:
```
.users | map(select(.age >= 30 and .active)) | sort_by(.age) | reverse | map({name, age})
{"users":[{"name":"ann","age":31,"active":true},{"name":"bob","age":45,"active":false},{"name":"cy","age":30,"active":true},{"name":"di","age":52,"active":true},{"name":"ed","age":29,"active":true},{"name":"flo","age":31,"active":true}]}
```
Output:
```
[{"name":"di","age":52},{"name":"flo","age":31},{"name":"ann","age":31},{"name":"cy","age":30}]
```
(`sort_by` is stable so `ann` precedes `flo`; `reverse` then swaps them.)

### Example 2

Input:
```
[(1,2) + (10,20)], {a:(1,2), b:(3,4)}, [.[] | .a?], (.[] | .a.b?)
[{"a":{"b":1}},{"a":5},3]
```
Output:
```
[11,12,21,22]
{"a":1,"b":3}
{"a":1,"b":4}
{"a":2,"b":3}
{"a":2,"b":4}
[{"b":1},5]
1
error
```
The last expression prints `1` for the first element; for `{"a":5}` the
`.b?` suppresses the error on `5`; for `3` the error comes from `.a`, which is
not optional, so evaluation stops with `error`.

### Example 3

Input:
```
reduce .[] as $o ({}; . + {($o.k): $o.v}), (map(.v) | add), sort_by(.k, -.v), (group_by(.k) | map([.[0].k, length])), (.[0] | keys), (.[2].v / 4)
[{"k":"b","v":1},{"k":"a","v":2},{"k":"b","v":3}]
```
Output:
```
{"b":3,"a":2}
6
[{"k":"a","v":2},{"k":"b","v":3},{"k":"b","v":1}]
[["a",1],["b",2]]
["k","v"]
0.75
```
