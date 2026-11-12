# inflate: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `I` is the compressed stream length in bytes, `O` the decompressed
length, `B` the number of blocks, `n_sym` the number of symbols in a code.

## Algorithm

The hex input is converted to bytes, and the DEFLATE stream is decoded in one
pass with a **table-driven Huffman decoder**: for each canonical code (fixed,
or rebuilt from the lengths of each dynamic block) lookup tables indexed by
the next stream bits give the symbol and its code length. Length and distance
symbols map to their base values and extra-bit counts through SPEC.md's
constant tables, and back-references copy from the output already produced.
Decoding stops at the first malformation; otherwise the output is converted to
hex.

## Required rules

1. **O(1) lookups per symbol.** Each symbol decodes with one or two table
   lookups (for example a root table of about 10 bits for literal/length codes
   and 8 for distance codes, plus second-level tables for longer codes). No
   bit-by-bit decoding, tree walk or search over code lengths.
2. **Per-block table work is O(n_sym + 2^R)**, `R` being the root width;
   nothing proportional to the longest possible code (2^15) is built per block.

## Complexity

Hex conversion is O(I + O). Decoding is O(I + O) plus O(n_sym + 2^R) per block
for building its tables; each back-reference costs O(length).
