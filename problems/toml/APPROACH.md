# toml: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `N` is the input size (at most 8 MB), `M` the output size, `K` the number
of keys in one table.

## Algorithm

**Decode** parses the document in a single pass by recursive descent, building a
tree of tables, arrays and scalars, then writes the tree as key-sorted tagged
JSON. **Encode** reads the tagged JSON into a tree of the same shape and writes
canonical TOML from it. A table maps keys to children and carries the definition
state that SPEC.md §1.3 needs (defined explicitly, implicitly, by a dotted key,
inline, sealed); header and key paths resolve against these tables as they are
read.

## Required rules

1. **Scalars are kept as text.** A scalar holds its canonical text. In encode
   mode the `value` texts of integers, floats, booleans and dates are written out
   exactly as given: never converted to numbers or dates and back.
2. **Floats are converted with correct rounding** when decoding.
3. **Dates and times are validated and canonicalised as text**, without a date
   library.

## Complexity

Each direction is O(N + M) apart from sorting each table's keys once, O(K log K)
per table. Every scan is bounded by the current token or line, so the parse is
linear. Nesting can be a few hundred levels deep, which the program must
handle.
