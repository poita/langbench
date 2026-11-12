# protowire: required approach

SPEC.md defines what the program outputs; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `L` the total input, `P` the bytes of one decode payload, `T` the length
of one encode text, `F ≤ 64` the fields of a message, `D ≤ 64` the nesting
depth.

## Algorithm

Parse the schema once into message descriptors, each field's type resolved to
a scalar kind or a message, with field lookup by number and by name. Each
request is then handled on its own, through a value tree with one node per
message instance.

- **decode:** convert the hex to bytes, decode them by recursive descent into
  a value tree, then render the tree as canonical text.
- **encode:** parse the text by recursive descent into a value tree, encode it
  and convert to hex.

## Required rules

1. **Encode is linear in the output size, independent of `D`**: no
   sub-message's bytes are produced once per ancestor, and no size is
   recomputed at each ancestor (for example, compute every node's size in one
   pass, then write).
2. **Decode is linear in the payload, independent of `D`**: each byte is read
   O(1) times, and unknown fields and groups are skipped without being decoded.
3. **Text and hex output are linear in their size**, never rebuilt per level of
   nesting.

## Complexity

The schema is parsed in O(schema size); a field lookup is O(1) expected or
O(log F). A decode request is O(P + output) and an encode request is O(T +
output). The whole run is O(L + total output).
