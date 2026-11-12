# jq: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `N` is the document size (at most 6 MB), `n` the length of an array
being processed, `k` the number of keys of an object.

## Algorithm

The filter is parsed once by recursive descent into a syntax tree, and the
document once, by recursive descent, into a tree of immutable values. A
tree-walking interpreter evaluates the filter: each node produces its output
stream one value at a time, in SPEC.md's order, and each top-level result is
printed as it is produced. Variables live in a persistent environment. An
object is an insertion-ordered map with expected O(1) key lookup.

## Required rules

1. **Values are shared, never deep-copied.** Binding a variable, indexing,
   iterating and `select` cost O(1) per value, whatever its size.
2. **Values are immutable**, including inside `reduce`: object `+` and `*` and
   array `+` cost O(|a| + |b|).
3. **Object construction `{...}` costs O(k) per object built.**
4. **An object's keys are sorted at most once**, however many comparisons and
   `keys` calls use that order.
5. **Sorting** (`sort`, `sort_by`, `group_by`, `unique`) is a stable
   comparison sort with O(n log n) comparisons and one evaluation of the key
   `[f]` per element; `group_by`, `unique`, `min` and `max` are otherwise
   linear.
6. **`add` is linear** in the total size of the elements.

## Complexity

Parsing and printing are O(N + output size). Field access is O(1) expected;
binding and iteration O(1) per value; sorting O(n log n) comparisons plus O(n)
key evaluations; string `/` O(length of the input). A nested generator costs
O(1) beyond the work of the expressions it evaluates. Nesting is at most 64
levels deep.
