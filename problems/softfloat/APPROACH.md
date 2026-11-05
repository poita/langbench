# softfloat: required implementation approach

SPEC.md defines what the program must output. This note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

## Overall approach

Read all of stdin into one byte buffer and walk it line by line. Dispatch on
the first one or two bytes of the line, decode the operands from fixed
positions (columns 4-11 and 13-20, or 5-12 for `sqrt`) with a direct hex-digit
loop, and call one function per operation that works on raw 32-bit patterns.
Each operation first handles NaN, infinity and zero by inspecting the bit
fields, then unpacks finite operands into an integer significand `m` and an
exponent `e` (value `m * 2^e`), computes an exact or truncated result in one
unsigned 64-bit integer plus a sticky flag, and hands it to a single shared
`round_pack` routine that rounds once to nearest-even onto the binary32 grid
(normal or denormal) and packs the bits. Each result is appended as 8 hex
digits plus `\n` to one output buffer, written once at the end. Total work is
O(L) for L input lines, with O(1) work per line bounded by about 32 loop
iterations (in `sqrt`).

## Required choices

1. **Integer-only arithmetic in fixed-width 64-bit words.** All significand
   work uses unsigned 64-bit integers (in a language without fixed-width
   integers, plain integers kept within the same bit widths). No host floating point anywhere, no 128-bit or
   arbitrary-precision integers, no exact rational arithmetic. The widest value
   needed is about 62 bits, so one machine word suffices and every operation is
   a handful of native instructions.
2. **Special values first, from the bit fields.** Classify NaN / infinity /
   zero with masks on the exponent and fraction fields and return the SPEC
   result immediately; only finite nonzero operands reach the arithmetic path.
   `sub a b` is `add a (b XOR 0x80000000)`.
3. **Unpack to (m, e) on the 2^-149 grid.** Normals give
   `m = frac | 2^23`, `e = biased - 150`; denormals give `m = frac`,
   `e = -149`. `div` and `sqrt` additionally normalise denormal significands so
   their top bit is bit 23, using a count-leading-zeros / bit-length primitive
   (one instruction), not a shift-by-one loop. `add` and `mul` need no
   normalisation.
4. **Leading-bit position by intrinsic.** Wherever the position of the highest
   set bit is needed (normalisation, `round_pack`), use the language's
   count-leading-zeros / bit-length operation, never a loop that shifts one
   bit at a time.
5. **add/sub: align with guard bits and a sticky flag.** Order operands by
   exponent, shift the larger significand left by a fixed number of guard bits
   (about 32-38, so the sum of the two aligned values still fits in 63 bits),
   shift the smaller one into the same frame, and fold any bits
   shifted out below the frame into a sticky flag (with the shift clamped so
   that a gap of 64 or more bits makes the small operand 0 with sticky set).
   Add or subtract in one 64-bit word; for an effective subtraction with sticky
   set, subtract one extra unit so the sticky residue stays non-negative. Exact
   cancellation returns `+0` directly. O(1); never build an exact wide sum.
6. **mul: one 24x24 -> 48-bit product.** `m = ma * mb` is exact in 64 bits;
   pass it with `e = ea + eb` and sticky false to `round_pack`.
7. **div: one hardware integer division.** With both significands normalised
   to 24 bits, compute `q = (ma << k) / mb` and `r = (ma << k) % mb` (k about
   30-32, so q has at least 30 significant bits) with a single native 64-bit
   divide (and remainder); sticky is `r != 0`. Do not perform bit-by-bit
   restoring long division and do not split the division into several steps.
8. **sqrt: digit-by-digit integer square root of one 64-bit radicand.** Make
   the exponent even (shift `m` left one bit if it is odd), scale the
   normalised significand left by an even amount (about 36-38) so the root has
   about 30 bits, and compute `floor(sqrt(n))` and the remainder with the
   classic restoring method (`bit` starting at the highest power of four not
   above `n`, at most 32 iterations of compare/subtract/shift). Sticky is
   `remainder != 0`. No floating-point estimate, no Newton iteration, and no
   library square root, integer or floating.
9. **One shared `round_pack(sign, m, e, sticky)`.** Find the leading bit,
   choose the target grid exponent `max(e_lead - 23, -149)`, split off the
   discarded bits, decide the increment from round bit, remaining bits and
   sticky (ties to even), handle the carry to 2^24 by renormalising, map an
   exponent above 127 to infinity, and emit denormals directly from the
   significand (a carry to 2^23 yields `00800000` without special casing).
   Rounding happens exactly once, on the final grid, so sticky is applied
   before any denormal shift. Discard shifts of 64 or more bits must be
   clamped explicitly.
10. **Input: one bulk read, fixed-offset parsing.** Read the whole input with
    one bulk read (or a few large reads into a growable buffer), then walk it
    with an index, finding each line end by scanning for `\n` or by stepping
    over the fixed line length. Decode each 8-digit operand at its fixed
    offset with an inline loop of eight `(v << 4) | digit` steps. No
    tokenising into strings, no line objects, no general-purpose integer
    parser, no per-character reads. In an interpreted language, where an
    eight-step loop costs more than one native call, the operand may instead
    be decoded by the standard library's base-16 integer conversion applied
    directly to the fixed 8-byte slice.
11. **Output: one preallocated byte buffer, one write.** Reserve about
    `9 * lines` bytes, format each result with a 16-entry digit table
    (eight table lookups plus `\n`), and write the buffer once at the end.
    In an interpreted language, formatting each result with the standard
    library's fixed-width (8-digit, zero-padded) hex conversion into a list
    that is joined and written once is the equivalent.

## Left to the implementer

- Exact number of guard bits in `add`, extra quotient bits in `div` and
  radicand scaling in `sqrt`, within the ranges above, as long as the results
  match SPEC.md.
- Whether operands are unpacked into a small struct or kept as separate
  locals, and whether classification uses booleans or direct mask tests.
- Whether `round_pack` normalises the significand to a fixed top bit first or
  computes the shift from the leading-bit position directly.
- Writing the result digits forward or backward, unrolling the hex loops,
  using a larger (e.g. 256-entry byte-pair) digit table, handling the
  optional trailing newline and a stray `\r`.
- Whether `add` orders operands by exponent alone or by magnitude.
- Module layout, naming, helper functions (provided small helpers are
  inlinable), and compiler flags beyond a normal optimised release build.

## Pitfalls

- Counting leading zeros or normalising with a loop that shifts one bit per
  iteration; `round_pack` runs on every operation, so a 20-60 iteration loop
  there costs more than the arithmetic itself.
- Bit-serial long division or a quotient loop for `div` when one native
  64-bit divide gives quotient and remainder; or two chained divisions where
  one suffices.
- Using the FPU (or a float-seeded estimate) for `sqrt` or `div`, which both
  violates the spec's intent and changes the cost model.
- Wide or arbitrary-precision intermediates (exact 277-bit sums, 128-bit
  types, big-integer libraries); a 64-bit word with a sticky flag is exact
  enough and far cheaper.
- Separate rounding paths per operation, or rounding to 24 bits and then
  again to the denormal grid (double rounding, which is also wrong); keep one
  shared single-rounding `round_pack`.
- Appending output one character at a time through a growable array whose
  append is a non-inlined runtime call, formatting (in a compiled language)
  through a general `printf`/string-format routine per line, or writing per
  line unbuffered.
- Splitting the input into a list of line strings or tokens, or (in a
  compiled language) decoding hex through a generic string-to-integer
  conversion that allocates or validates.
- Handling huge alignment gaps in `add` or underflowing shifts in
  `round_pack` with a loop or a wider type; clamp the shift count (64 or more
  means "all bits go to sticky") with one comparison.
