# softfloat: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `L` is the number of input lines (at most 100,000).

## Algorithm

Each line is evaluated on the raw 32-bit patterns. NaN, infinity and zero
operands are classified from the bit fields and give SPEC.md's result directly;
`sub a b` is `add a (−b)`. Finite operands are unpacked into an integer
significand `m` and exponent `e` (value `m·2^e`), with denormals normalised
before `div` and `sqrt`. Each operation computes a truncated integer result
plus a sticky bit, and one shared round-and-pack step rounds it to
nearest-even directly onto the binary32 grid (normal or denormal):

- **add/sub:** align the smaller operand with a fixed number of guard bits,
  folding the bits shifted out into the sticky bit, then add or subtract.
- **mul:** the exact 48-bit product of the two 24-bit significands.
- **div:** one integer division of the shifted dividend significand by the
  divisor's; the sticky bit is a nonzero remainder.
- **sqrt:** after making the exponent even, a restoring digit-by-digit integer
  square root of the scaled significand; the sticky bit is a nonzero remainder.

## Required rules

1. **Integer arithmetic of bounded width.** Every intermediate fits in 64
   bits. No host floating point, no arbitrary-precision or 128-bit integers,
   no exact rationals, and no exact wide sums: guard bits and a sticky bit
   carry what is shifted out.
2. **Division is one integer divide** giving quotient and remainder, not a
   bit-serial long division.
3. **Square root is the restoring digit-by-digit method**: no Newton iteration,
   floating-point estimate, or library square root, integer or floating.
4. **Rounding happens once**, in the shared round-and-pack step.

## Complexity

O(1) per line, so O(L) in total; the square root takes at most about 32
digit steps.
