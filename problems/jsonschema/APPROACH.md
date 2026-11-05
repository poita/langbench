# jsonschema — implementation approach

SPEC.md defines what the output must be. This note fixes how the program
computes it. Below, N is the input size in bytes, S the number of schema
objects across `schema` and all `remotes`, P the size of one compiled regular
expression, L the length of one string in code points, and n the number of
elements or members of one array or object instance.

## Overall approach

Read the whole input, parse it once into an in-memory value tree, then
**compile** the schema and every remote document, in one walk (SPEC.md 6.2),
into an arena of typed schema nodes. A node holds only the keywords that
are present, already decoded into evaluation-ready form: integer bounds,
canonical numbers, compiled regexes, child node indices and pre-resolved
references. Then each instance is validated by a recursive evaluator over
those nodes that returns accept/reject plus, only when a caller needs them,
positional annotation bitsets. Results are appended to one output buffer
that is written once at the end. The raw schema JSON is never consulted
during evaluation.

## Required choices

1. **Input and output.** Read all of stdin in one call and parse it with a
   single recursive-descent pass over the bytes (O(N)). Accumulate the
   `valid`/`invalid` lines in one buffer and write it once.
2. **Value representation.** A tagged value: null, bool, number, string,
   array (a contiguous vector of values) and object (a contiguous vector of
   (key, value) members in document order). Object key lookup may use a
   linear scan for small objects and must use a hash index for larger
   ones; the member order gives every member a stable position 0..n-1,
   which the annotations of item 7 use. String escapes are decoded at parse
   time. Subtrees are moved or referenced, never deep-copied.
3. **Numbers.** Parse each literal once into a canonical exact decimal:
   sign, integer mantissa with trailing zeros stripped (folded into the
   exponent), and exponent; zero is mantissa 0, exponent 0, no sign. The
   mantissa is a machine integer when it fits and an arbitrary-precision
   integer otherwise; equality, ordering,
   `integer` and `multipleOf` are exact (SPEC.md 3.1) and do not allocate on
   the machine-integer path. Count bounds (`maxLength`, `minItems`,
   `minContains`, ...) are converted to machine integers once at compile
   time (saturating for huge values) and compared as integers.
4. **Compiled schema nodes.** Compilation visits each schema object once
   (O(S) plus the schema's bytes) and creates one node per schema object,
   stored in an arena and referred to by index or pointer. Each node records
   its base URI as a small interned integer id, and fields for the keywords
   SPEC.md defines: the `type` set as a bitmask, `enum`/`const` values,
   numeric bounds, integer count bounds, regexes, `required` and
   `dependentRequired` name lists, a hash map from property name to child
   node for `properties`, lists of (regex, child) for `patternProperties`,
   and child indices for every other applicator. Unknown keywords are
   dropped. Evaluating a node tests only the fields that are present; it
   never looks keywords up by name.
5. **Registry and references.** During the same walk, fill maps from base
   URI to resource node, from (base, anchor) to node, the dynamic-anchor
   set, and from each schema value in the parsed tree to its node (so a
   JSON Pointer walked over the value tree from a resource root maps to a
   node). Each `$ref` is resolved at most once (RFC 3986 resolution,
   fragment split, percent-decoding, pointer or anchor lookup), either in
   a pass after all documents are compiled or on its first evaluation,
   and the target node is stored in the referencing node. Only references
   reachable during validation are guaranteed to resolve, so an
   unresolvable one is recorded as such, not treated as an error. A
   `$dynamicRef` is resolved the same way to its static target and
   additionally records, at compile time, whether it is dynamic
   (plain-name fragment that is a dynamic anchor in its document) and the
   anchor name as an interned id. Evaluation performs no URI parsing,
   string concatenation or pointer walking.
6. **Dynamic scope.** A stack of base-URI ids, pushed on entering a node
   whose base differs from the top and popped on exit, amortised O(1).
   Resolving a dynamic `$dynamicRef` scans the stack outermost-first with
   one hash lookup on the integer pair (base id, name id) per entry; the
   first base under which the name is a dynamic anchor gives the target,
   which is the node the plain anchor map holds for that pair (so an
   `$anchor` of the same name wins, SPEC.md 6.3).
7. **Annotations.** Evaluated items and evaluated properties are bitsets
   (or boolean arrays) indexed by array index and by object member
   position, allocated lazily on first mark; merging is a bitwise OR.
   The evaluator takes a flag saying whether the caller needs annotations.
   A node *collects* when the flag is set or it has an `unevaluated*`
   keyword; only a collecting node marks bits for its own keywords and
   sets the flag on its in-place applications (`$ref`, `$dynamicRef`,
   `allOf`, `anyOf`, `oneOf`, `if`/`then`/`else`, `dependentSchemas`).
   `not`, `propertyNames` and children applied to array elements or
   member values never get the flag. In a non-collecting node no bitsets
   are built, `anyOf` stops at the first accepting branch, `contains`
   without `maxContains` stops once `minContains` (default 1) matches are
   found, and `if` without `then`/`else` is skipped. A collecting node
   evaluates every `anyOf` branch and every `contains` element. `oneOf`
   stops at the second accepting branch in either case.
8. **Keyword order and early exit.** Within a node evaluate in this order
   and return reject at the first failure: `type`; `const`/`enum`; the
   assertions for the instance's own type (bounds, lengths, `pattern`,
   `required`, `dependentRequired`, `uniqueItems`); the child applicators
   (`prefixItems`, `items`, `contains`, `properties`, `patternProperties`,
   `additionalProperties`, `propertyNames`); the in-place applicators
   (`$ref`, `$dynamicRef`, `allOf`, `anyOf`, `oneOf`, `not`,
   `if`/`then`/`else`, `dependentSchemas`); finally `unevaluatedItems` /
   `unevaluatedProperties`.
9. **Object members in one pass.** For `properties`, `patternProperties`
   and `additionalProperties`, iterate the instance's members once: look the
   name up in the `properties` map, test each `patternProperties` regex
   once, and apply `additionalProperties` only to members that matched
   neither, using the flags from that same pass. `required` and
   `dependentRequired` use the object's key lookup of item 2.
10. **Regular expressions.** Each distinct pattern is parsed and compiled
    once, at schema compile time (a cache keyed by pattern text), into a
    small instruction program (char, class as sorted code-point ranges,
    any, split, jump, `^`, `$`, `\b`, `\B`, match). Matching is a
    depth-first backtracking search with a visited bitset over
    (instruction, position) shared by all start positions of the
    unanchored search, so a membership test costs O(P·L) at worst.
    Counted repetition `{n,m}` is expanded into copies of its body so that
    the (instruction, position) pair is the whole matcher state, which
    also stops empty loops such as `(a*)*` from cycling. The
    subject is decoded from UTF-8 to code points at most once per test (or
    iterated in place); an all-ASCII subject may be matched on bytes.
11. **String length** is the number of UTF-8 lead bytes (bytes that are not
    `10xxxxxx`), counted without decoding or allocating.
12. **Equality and `uniqueItems`.** JSON equality is structural with
    order-independent object comparison by key lookup, checking type and
    size before contents; `enum` scans its elements linearly. `uniqueItems` hashes
    each element with a hash consistent with JSON equality (canonical
    numbers; object members combined order-independently) and compares
    only elements whose hashes collide: expected O(total element size), not
    O(n²) comparisons.
13. **Recursion.** The evaluator is recursive; run it on a thread or stack
    large enough for the deepest meta-schema nesting rather than converting
    it to an explicit stack.

## Left to the implementer

Concrete container types (hash map flavour, bitset vs boolean vector,
small-object threshold for the hash index), struct and enum layout of nodes
and values, whether children are arena indices or pointers, how base URIs
and names are interned, the bigint representation and its arithmetic,
the regex AST and instruction encoding, reuse of scratch buffers for the
visited bitset, module structure, naming and error handling for malformed
input. Micro-optimisations that do not change the algorithms above (for
example skipping start positions after a leading `^`, or an ASCII fast path
for `\w`/`\d` classes) are allowed.

## Pitfalls

- Interpreting the raw schema JSON on every evaluation: looking each
  keyword up by name (dozens of hash or string lookups per node visit even
  when absent), or dispatching on keyword strings per member. Compile once
  (item 4).
- Re-resolving `$ref`/`$dynamicRef` on every evaluation: re-running URI
  resolution, percent-decoding, string concatenation of `base#name` keys
  and JSON Pointer walks inside the hot path. This alone makes the
  OpenAPI meta-validation input several times slower.
- Looking up a node's base URI in a hash map keyed by node on every visit,
  or comparing base URIs as strings when pushing the dynamic scope; use the
  interned id stored in the node.
- Shrinking a dynamic array to pop the scope in a way that makes the next
  push reallocate and copy the whole stack.
- Property annotations as hash sets or lists of name strings that are
  copied and merged at every level; use positional bitsets (item 7).
  Equally, building annotation sets when no `unevaluated*` keyword can see
  them.
- Decoding a property name or string to a code-point array once per
  pattern per call, or re-looking a compiled regex up by its pattern text
  at each use; compiled regexes belong in the node.
- Unmemoised backtracking or per-start-position restarts that reset the
  visited set; both can turn a linear search exponential or quadratic.
- Allocating arbitrary-precision numbers to compare a length or count
  against a bound.
- Pairwise O(n²) `uniqueItems`.
- Allocating a new string value for every member name under
  `propertyNames`, or deep-copying `enum`/`const` values and instance
  subtrees.
- Per-object hash maps for every small object in the input, and
  per-line writes to stdout.
