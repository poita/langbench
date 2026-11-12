# jsonschema: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `N` is the input size (at most 2 MB), `S` the number of schema objects
across `schema` and `remotes`, `P` the length of one pattern, `L` the length of
one string, `n` the number of elements or members of one array or object.

## Algorithm

- **Parse** the input once, by recursive descent, into a tree of JSON values;
  objects keep their members in document order.
- **Compile** the schema and every remote in one walk (SPEC.md §6.2), building
  the registry of resources, anchors and dynamic anchors and turning each schema
  object into a node with its keywords decoded, its patterns compiled and its
  subschemas as child nodes.
- **Validate** each instance with a recursive evaluator over the nodes that
  returns accept/reject and, where an `unevaluated*` keyword needs them, the
  evaluated-items and evaluated-properties sets. The dynamic scope is a stack
  of base URIs.

## Required rules

1. **Compile once.** Keyword decoding, URI and JSON Pointer resolution and
   pattern compilation happen once per schema object or reference, never per
   instance.
2. **Pattern tests are O(P·L).** Counted repetition is expanded, and the search
   never repeats a (pattern position, subject position) state, across all start
   positions: for example a backtracking search memoised on visited pairs. No
   exponential backtracking.
3. **`uniqueItems` is expected linear** in the total element size, for example
   by hashing consistently with JSON equality. No pairwise comparison of all
   elements.
4. **Member lookup by name is expected O(1)** for `required`,
   `dependentRequired` and `properties`.

## Complexity

Parsing is O(N); compilation is O(S) plus the schema's size and patterns. Each
pattern test is O(P·L), `uniqueItems` expected O(total element size), and a
dynamic `$dynamicRef` O(scope depth). Schemas nest a few hundred levels deep
(the OpenAPI meta-schema), which the evaluator must handle.
