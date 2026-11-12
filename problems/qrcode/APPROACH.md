# qrcode: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `v` is the version, `n = 4v + 17` (at most 177) the symbol side, `T` (at
most 3706) the total codewords, `E` (at most 30) the ECC codewords per block and
`len` the text length in bytes.

## Algorithm

Each query is encoded independently, following SPEC.md's steps: choose the mode
and the smallest version whose capacity holds the stream's bit length; write
the segment as a bit stream, then terminate, byte-align and pad it; compute each
block's Reed-Solomon ECC over GF(2^8) as the remainder of polynomial division by
the degree-`E` generator and interleave the blocks; draw the function patterns
and place the codeword bits along the zigzag; then apply the fixed mask, or for
`auto` apply each of the eight masks with its format bits and keep the one with
the lowest SPEC.md §12 penalty, ties going to the lower mask.

## Required rules

1. **Version choice computes bit lengths in closed form** (SPEC.md §2), O(len +
   40) in all, and the payload is encoded once, for the chosen version.
2. **Function patterns and data are placed once per query**, O(n²), not once
   per mask.
3. **`auto` scores all eight masks in full**, on the complete masked symbol: no
   early exit once a partial score exceeds the best, and no incremental scoring
   between masks.

## Complexity

Per query: O(len + 40) to choose the mode and version, O(T·E) for error
correction, O(n²) for the grid and each mask's penalty, so O(8·n²) with `auto`.
