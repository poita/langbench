# json: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `n` is the input size (at most 2,000,000 bytes), `m` the number of
members of one object.

## Algorithm

Three phases, stopping at the first error:

- **Validate** the whole input as strict UTF-8 (SPEC.md, Input).
- **Parse** it by recursive descent into a tree. Strings are stored decoded;
  numbers as their canonical text; arrays and objects keep all their elements
  and members, duplicates included, in input order.
- **Serialise** the tree from the root. Each object's members are ordered by a
  stable sort on their keys in SPEC.md's UTF-16 order; of each run of equal
  keys, the last member is written.

## Required rules

1. **Validation and parsing are single forward passes** (or one fused pass),
   with no backtracking.
2. **Serialisation is O(n) apart from key sorting**: no output text built per
   subtree and then copied into its parent, which costs O(n·depth).

## Complexity

Validation, parsing and serialisation are O(n), plus O(m log m) key comparisons
per object, each costing up to the length of the keys' common prefix. Nesting
reaches 512 levels, which the program must handle.
