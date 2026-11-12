# softfloat — Software IEEE-754 binary32 arithmetic

Implement IEEE-754 single-precision (binary32) addition, subtraction,
multiplication, division and square root in software, with round-to-nearest-even
and full gradual underflow (denormals). Operands and results are exchanged as raw
32-bit bit patterns, so every bit of the result is checked.

Do the arithmetic yourself with integer operations: don't use the hardware's
or the language's floating-point arithmetic, square root or conversions, or a
software floating-point library, to compute any result. Every output bit
pattern must be exactly right.

## Input

Standard input is UTF-8 text with one operation per line:

    <op> <a> <b>        for op in add sub mul div
    sqrt <a>

- Tokens are separated by exactly one ASCII space.
- `op` is one of `add`, `sub`, `mul`, `div`, `sqrt` (lowercase).
- `a` and `b` are exactly 8 lowercase hexadecimal digits (`0`-`9`, `a`-`f`)
  giving the 32-bit IEEE-754 binary32 bit pattern of the operand, most
  significant nibble first (so `3f800000` is 1.0, `bf800000` is -1.0,
  `7f800000` is +infinity, `00000001` is the smallest denormal).
- Any 32-bit pattern may appear, including both signs of zero, infinities,
  denormals, and NaNs with any sign and any payload (quiet or signaling).
- Lines are terminated by `\n`. The last line may or may not end with a
  newline. There are no blank lines, no leading/trailing spaces and no
  malformed lines. A file contains between 1 and 100,000 lines (it is never
  empty).

## Output

Print exactly one line per input line, in input order, each terminated by `\n`:
the result of the operation as exactly 8 lowercase hexadecimal digits (the
binary32 bit pattern, zero-padded, no prefix).

## Semantics

The result is the IEEE-754 binary32 value of the exact mathematical result
rounded to nearest, ties to even ("roundTiesToEven"), with these rules:

Rounding and range
- The exact result is rounded once, to the nearest representable binary32
  value; if it lies exactly halfway between two representable values, the one
  whose least significant significand bit is 0 is chosen.
- Denormal (subnormal) operands and results are fully supported. There is no
  flush-to-zero: results whose magnitude is below 2^-126 round to the nearest
  denormal (or to zero, or up to the smallest normal 2^-126) using the same
  ties-to-even rule at the denormal grid spacing 2^-149.
- Results whose rounded magnitude would exceed the largest finite value
  (`7f7fffff`, about 3.4e38) become infinity of the same sign. Precisely: the
  result is +/-infinity when the exact magnitude is >= 2^128 - 2^103 (the
  midpoint between the largest finite value and 2^128 rounds to infinity
  because the largest finite value has an odd significand).
- Rounding for `sub a b` is identical to `add a (-b)`.

NaN
- If any operand is a NaN (exponent field all ones and nonzero fraction, with
  either sign, quiet or signaling), the result is the canonical quiet NaN
  `7fc00000`.
- Every invalid operation also produces `7fc00000`:
  `(+inf) + (-inf)`, `(+inf) - (+inf)` (and the sign-symmetric cases),
  `0 * inf`, `0 / 0`, `inf / inf`, `sqrt(x)` for any x < 0 including `-inf`.
- No other NaN bit pattern is ever output.

Infinities
- `inf + x`, `inf - x` for finite x is `inf` with the sign of the infinity;
  `inf + inf` and `(-inf) + (-inf)` keep their sign.
- `inf * x` for x != 0 and `inf / x` for finite x are infinity with sign
  `sign(a) XOR sign(b)`.
- `x / inf` for finite x is zero with sign `sign(a) XOR sign(b)`.
- `x / 0` for finite nonzero x is infinity with sign `sign(a) XOR sign(b)`
  (`div 3f800000 80000000` = `ff800000`).
- `sqrt(+inf)` = `+inf`.

Signed zeros
- `mul` and `div`: a zero result always carries sign `sign(a) XOR sign(b)`,
  whether the exact result is zero or a nonzero result rounded to zero.
  `0 * -x = -0`, `-0 * -0 = +0`, `0 / -3 = -0`, `-0 / inf = -0`,
  `mul 80000001 3f000000 = 80000000` (-2^-150 rounds to -0).
- `add`/`sub`: when the exact sum is zero and both (effective) addends are
  zeros of the same sign, the result has that sign: `-0 + -0 = -0`,
  `-0 - +0 = -0`. In every other exact-zero case the result is `+0`:
  `+0 + -0 = +0`, `x + (-x) = +0`, `x - x = +0`, `-0 - -0 = +0`.
- Adding or subtracting a zero to a nonzero finite value returns that value
  unchanged (`-0 + 3f800000 = 3f800000`).
- `sqrt(+0) = +0`, `sqrt(-0) = -0`.

Floating-point exceptions and flags are not modelled; only the result value
matters.

## Worked examples

Example 1

    input:
    add 3f800000 3f800000
    sub 3f800000 3f800000
    mul 40400000 c0400000
    div 3f800000 40400000
    sqrt 40000000

    output:
    40000000
    00000000
    c1100000
    3eaaaaab
    3fb504f3

1+1 = 2; 1-1 = +0; 3 * -3 = -9; 1/3 rounds to 0x3eaaaaab (the exact value
0.333... lies above the midpoint so the last bit rounds up); sqrt(2) =
0x3fb504f3.

Example 2 (special values and signed zeros)

    input:
    add 7f800000 ff800000
    mul 7f800000 00000000
    div 00000000 00000000
    sqrt 80000000
    sqrt bf800000
    mul 00000000 bf800000
    add 80000000 80000000
    add 80000000 00000000
    div bf800000 00000000
    add 7fc12345 3f800000

    output:
    7fc00000
    7fc00000
    7fc00000
    80000000
    7fc00000
    80000000
    80000000
    00000000
    ff800000
    7fc00000

Example 3 (rounding at the edges)

    input:
    add 7f7fffff 73000000
    add 7f7fffff 72ffffff
    div 00000001 40000000
    div 00000003 40000000
    add 3f800000 33800000
    add 3f800001 33800000
    add 3f800000 33000000
    mul 00000001 3f000000

    output:
    7f800000
    7f7fffff
    00000000
    00000002
    3f800000
    3f800002
    3f800000
    00000000

- `7f7fffff + 2^103`: the exact sum is the midpoint between the largest finite
  value and 2^128; ties-to-even picks 2^128, which overflows to `+inf`.
  Adding anything smaller than 2^103 leaves the largest finite value unchanged.
- `2^-149 / 2` is exactly half the smallest denormal; ties-to-even gives `+0`.
  `3 * 2^-149 / 2 = 1.5 * 2^-149` rounds to even, i.e. `2 * 2^-149`.
- `1 + 2^-24` is a tie between 1 and 1+2^-23 (the ulp of 1 is 2^-23); the
  even choice is 1. `(1+2^-23) + 2^-24` is a tie whose even neighbour is
  `1+2^-22`. `1 + 2^-25` is below the midpoint and simply rounds to 1.
- `2^-149 * 0.5` is again half the smallest denormal and rounds to `+0`.

## Input sizes

The largest test has 100,000 lines (about 2 MB of input); the suite totals
about 350,000 operations.

## Notes for implementers

- The exact sum of two binary32 values can need up to 277 bits, but a 3-bit
  guard/round/sticky scheme after aligning to about 27 bits gives exactly the
  same rounded result.
- Division never produces an exact tie when the result is normal, but it does
  when the result is denormal (see Example 3), so the sticky bit must be
  applied before the denormal rounding shift, not after (rounding to 24 bits
  first and then to the denormal grid is double rounding and gives wrong
  answers).
- Square root never produces a tie, and its result is never denormal (the
  square root of the smallest denormal is about 2^-74.5), so denormals only
  need handling on the input side of `sqrt`.
- Denormal operands must be normalised (or the algorithm given enough extra
  bits) before `div` and `sqrt`: a fixed number of extra quotient bits that is
  sufficient for normal operands is not sufficient when a denormal operand
  has only a few significant bits.
- The smallest normal `00800000` is the natural continuation of the denormal
  grid: rounding a denormal-range result up to 2^23 units of 2^-149 gives the
  bit pattern `00800000` directly.
