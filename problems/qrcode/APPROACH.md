# qrcode — required approach

SPEC.md defines what the program does. This note defines how it is built. Where
the two seem to disagree, SPEC.md wins.

## Overall approach

Read all of standard input with one bulk read and walk it line by line. For
each query: select the mode and version arithmetically, pack the segment
straight into data codeword bytes, compute Reed-Solomon ECC per block with
GF(2^8) log/antilog tables, and interleave. Build one unmasked base grid (one
byte per module, row-major) together with a parallel function-module map,
then place the codeword bits along the zigzag. For a fixed mask, render that
mask once. For `auto`, render each of the eight masks into a reused scratch
grid and score it with a linear-time penalty pass (N1 and N3 fused in one
scan per row and per column, N2 over adjacent row pairs, N4 from a dark
count), keeping the lowest. Rows are appended as `#`/`.` bytes to one output
buffer, written once at the end.

Sizes below: `v` is the version, `n = 4v + 17` (at most 177) the symbol
side, `T = raw(v) div 8` (at most 3706) the total codewords, `E` (at most
30) the ECC codewords per block, `L` the input size in bytes.

## Required choices

1. **Input, O(L).** One bulk read of stdin into a byte buffer; lines are
   views into it, split at `\n`. The ECL is the first byte, the mask token
   runs to the second space, and the text is the rest of the line as raw
   bytes. Do not decode the text as Unicode, and do not read stdin line by
   line through an unbuffered stream.
2. **Mode and version, O(len + 40).** Mode by one or two linear scans over
   the bytes; the alphanumeric value of a byte comes from a 256-entry lookup
   table (or an equivalent O(1) test), not a search of the 45-character
   string. Version by the closed-form bit-length formula of SPEC section 2,
   checked against `8*C(v, ecl)` for `v = 1..40`. Never encode the payload
   once per candidate version.
3. **Bit packing, O(T).** The bit writer appends bits directly into a byte
   array (an accumulator plus a bit position), most significant bit first.
   No intermediate sequence with one element per bit (booleans, characters
   or strings of `0`/`1`) that is converted to bytes afterwards. Terminator,
   byte alignment and `0xEC`/`0x11` padding are applied to that byte array.
4. **GF(2^8) arithmetic.** Build `exp` (doubled to 512 entries, or reduced
   mod 255) and `log` tables for 0x11D once at start-up. Multiplication is
   two table lookups plus one addition with an explicit zero check. No
   shift-and-add (carry-less) multiplication loop in the encoder.
5. **Reed-Solomon, O(T·E) per query.** Compute the degree-`E` generator once
   per query (all blocks of a query share it), then encode each block with
   the standard LFSR polynomial division: for each data codeword compute
   `factor = data ^ rem[0]`, shift the `E`-byte remainder register by one,
   and XOR in `gen[j] * factor` for every `j`, skipping the XOR loop when
   `factor` is zero. Blocks are ranges of the data codeword array; ECC goes
   into a per-block (or one flat `B×E`) array. Interleaving is the two
   nested loops of SPEC section 6 writing into one preallocated array of
   `T` bytes.
6. **Grid representation.** The symbol is a flat row-major array of `n*n`
   bytes, one byte per module (0 light, 1 dark), indexed `y*n + x`; the
   XOR of choice 8 and the window of choice 9 rely on these values. A second `n*n` byte or boolean
   array marks function modules. No nested per-row heap objects for the
   working grid (the bulk-string exception under "Left to the implementer"
   aside), no maps or sets of coordinates, and no bit-packed
   (several modules per machine word) representation: every
   implementation scans modules one byte at a time.
7. **Function patterns and placement, O(n²).** Draw finders, timing,
   alignment, dark module, format area and version information once into
   the base grid, marking each as function. Then walk the zigzag of SPEC
   section 10 once, testing the function map, and write codeword bits
   (`(cw[i >> 3] >> (7 - (i & 7))) & 1`). The base grid and function map
   are built once per query, not once per mask.
8. **Rendering a mask, O(n²).** Copy the base grid into a scratch grid
   allocated once per query, XOR 1 into every non-function module where the
   mask condition holds, then overwrite the 15 format modules with that
   mask's format bits. The mask condition is evaluated per module from
   `(x, y)` with the SPEC formula (a precomputed per-mask table of modules
   to flip is equally acceptable). Do not apply and then undo a mask in
   place. With a fixed mask the base itself may be masked in place, since
   nothing needs undoing.
9. **Penalty, O(n²) per mask, one linear pass per line.** For each row and
   each column, one scan keeps the current run colour and length (N1: add
   `run − 2` when a run of at least 5 ends, including at the line end) and
   an 11-bit sliding window of the last 11 modules, compared after each step
   (once at least 11 modules are in) with the two pattern constants `0x5D0`
   (`#.###.#....`) and `0x05D` (`....#.###.#`), adding 40 for each match
   (N3). N2 is one pass over pairs of adjacent rows comparing the four
   modules of each 2×2 block. N4 counts dark modules (in one of the passes
   or a separate sum) and applies SPEC's integer formula. Total work per
   query with `auto` is `8 × O(n²)`.
10. **Mask choice.** Iterate masks 0..7, keep the strictly lowest penalty
    (ties keep the lower mask), and keep the best grid by copying it into a
    second buffer, by swapping buffers, or by re-rendering the winning mask
    once at the end.
11. **Output, O(n²) per query.** Append `version v mask m\n`, then each row
    as `n` bytes plus `\n`, then the blank line, into one output buffer (or
    one large buffered writer) that is written once at the end. Rows are
    produced by a direct byte translation of the grid (0/1 to `.`/`#`), not
    by per-module formatted printing.

## Left to the implementer

- Container types, struct layout, naming, module structure; whether the
  constant tables are literal arrays or computed; whether alignment
  positions come from the SPEC list or a formula that reproduces it.
- Whether the RS remainder register shifts by moving bytes or is a circular
  buffer; whether `gen` is stored as coefficients or as their logs; whether
  generators are cached across queries by degree.
- Whether columns are scanned with strided access into the row-major grid
  or from a transposed copy made once per mask.
- Whether N2 and N4 share a pass with the row scan, and whether the mask
  condition is a switch inside the loop, one loop per mask, or a cached
  per-(version, mask) flip table.
- Loop-level micro-optimisations: bounds-check elimination, integer widths,
  unrolling, pointer versus index style.
- In languages whose fastest idiom is a native bulk operation over strings
  or byte arrays (splitting a row on one colour to find runs, counting
  substring occurrences of the two N3 patterns, translating a byte row to
  characters), using it is fine as long as the work stays linear per line
  and the results are identical. Such an implementation may derive one
  string per row and per column from the rendered grid once per mask to feed
  those operations. Neither N3 pattern can overlap a copy of itself, so a
  non-overlapping substring count is exact.

## Pitfalls

- N3 by comparing all 11 modules at every window position, or by building a
  slice/substring per position: 11× the necessary work on the hottest path.
  Use the rolling 11-bit window.
- Reading modules through a closure, accessor with coordinate bounds
  checks, or a function chosen per call inside the inner penalty loops when
  the language does not reliably inline it; read the flat array directly.
- A bit buffer with one element per bit, or strings of `0`/`1` characters
  joined and reparsed into bytes.
- Shift-and-add GF multiplication inside the RS inner loop (eight
  iterations per product instead of two lookups), or recomputing the
  generator polynomial per block.
- Rebuilding function patterns and re-placing data for each of the eight
  masks, or allocating fresh grids per mask; applying a mask to the base in
  place and then undoing it, which costs an extra full pass.
- Bit-packing rows into machine words with popcount or shift tricks for the
  penalty: a different algorithm, not permitted here.
- Searching the 45-character alphanumeric string for each byte instead of a
  lookup table.
- Formatting each module or row through a general-purpose formatter, or
  writing/flushing per row; building the output by repeated immutable
  string concatenation.
