# bigint — required approach

SPEC.md defines what the program does; this note defines how it is built. Where
the two seem to disagree, SPEC.md wins.

## Overall approach

Read all of standard input into memory once, walk it line by line, and split
each line at its two spaces. Parse both operands directly into sign-magnitude
integers whose magnitudes are little-endian arrays of base-10⁹ limbs. Evaluate
the operator with classical (quadratic) limb algorithms: linear add, subtract
and compare, schoolbook multiplication, single-limb short division or Knuth's
Algorithm D for long division, and left-to-right binary exponentiation built
on the schoolbook multiply. Append each result's decimal form to one output buffer
and write that buffer to standard output once at the end.

Sizes below are in limbs: an operand with `D` significant digits has
`n = ⌈D/9⌉` limbs (at most about 5,556 for a 50,000-digit operand).

## Required choices

1. **Representation.** A value is a sign plus a magnitude. The magnitude is a
   little-endian sequence of limbs, each in `[0, 10⁹)`, stored in an unsigned
   32-bit element type (or the language's plain integer where it has no
   fixed-width unsigned type), with no most-significant zero limbs; zero is the empty magnitude and is never
   negative. All limb arithmetic uses 64-bit intermediates: a limb product
   plus a limb plus a carry stays below 2⁶³. A power-of-ten base makes parsing
   and printing linear, and 10⁹ is the largest power of ten whose products fit
   in 64 bits. Do not use a binary base (2³², 2⁶⁴) or a base-10 digit array,
   and do not use 128-bit limbs or products.
2. **Input.** Read the whole input in one bulk read and scan it for `\n` and the
   two separating spaces; do not split it into a list of line strings first if
   the language makes that an extra full copy, and never read it byte by byte
   through an unbuffered stream. Treat the operator as a token: `cmp` is the
   only three-character operator.
3. **Parsing, O(D).** Skip the sign and leading zeros, then convert the digits
   nine at a time from the right end, each chunk accumulated into one limb with
   machine arithmetic. A token of only zeros (with or without `-`) is zero with
   positive sign. The exponent of `^` is parsed the same way and then folded
   into a machine integer only after the negative-exponent error check (it is
   at most 5,000 when valid, while a negative exponent may have 50,000
   digits; its parity comes from its lowest limb).
4. **Output, O(n).** Print `-` for negative values, the top limb without
   padding, then every lower limb as exactly nine zero-padded digits, appending
   into the single output buffer. Errors print `error`; `cmp` prints `-1`, `0`
   or `1`. One write of the whole buffer at the end.
5. **Comparison, O(n).** Compare signs, then limb counts, then limbs from the
   most significant end. Never compare by subtracting.
6. **Addition and subtraction, O(n + m).** Same signs add magnitudes; different
   signs compare magnitudes and subtract the smaller from the larger, taking
   the larger one's sign. Subtraction is addition with the second sign flipped
   (flip the sign without copying the magnitude; zero stays non-negative).
   Carry and borrow are single
   compare-and-adjust steps per limb, not divisions. Trim the result.
7. **Multiplication, O(n·m), schoolbook.** Allocate the `n + m` result limbs
   zeroed once. Loop rows over the limbs of the shorter operand and columns
   over the longer one, so the inner loop is the long one; skip a row whose
   multiplier limb is zero. In the inner loop compute
   `t = r[i+j] + a_i·b_j + carry` in 64 bits and split it into the new limb
   and carry with one division by the base, e.g. `carry = t / 10⁹`,
   `r[i+j] = t − carry·10⁹` (in compiled languages the base is a
   compile-time constant so the division becomes a multiply-shift). The
   row's final carry is below 10⁹ and is stored in the next limb above the
   row (which is still zero) or propagated upward; both are fine. Do not
   implement Karatsuba, Toom-Cook, FFT/NTT or any other subquadratic method: every
   implementation uses the same quadratic kernel.
8. **Division, one call returns quotient and remainder.** If the divisor is
   zero the query prints `error` before any arithmetic. If `|a| < |b|` the
   quotient is zero and the remainder is `|a|` (no division work). A one-limb
   divisor uses short division from the top limb with a 64-bit running
   remainder, O(n). Otherwise use Knuth's Algorithm D in base 10⁹, O((n−m+1)·m):
   - normalise by multiplying both operands by the single-limb factor
     `d = ⌊10⁹ / (v_top + 1)⌋`, giving the dividend one extra top limb, so the
     divisor's top limb is at least 10⁹/2;
   - for each quotient limb, from the top, estimate `q̂` from the top two
     dividend limbs divided by the top divisor limb, and correct it with the
     standard test against the second divisor limb and third dividend limb
     (at most two decrements);
   - subtract `q̂·v` from the current dividend window in one fused pass,
     in place in the normalised dividend array: per limb compute
     `p = q̂·v_i + carry`, split `p` into low limb and new carry with one
     division by the constant base, then subtract the low limb and the
     borrow with a single compare-and-adjust (borrow is 0 or 1); after the
     top limb, if the window went negative, decrement `q̂` and add `v` back
     once;
   - the remainder is the low `m` limbs of the working array divided by `d`
     (a short division).
   Sign rules per SPEC: the quotient is negative iff the signs differ, the
   remainder takes the dividend's sign, and zero results are non-negative.
   `/` and `%` both run this routine and print the part they need; never
   derive the remainder as `a − q·b`.
9. **Exponentiation, O(log b) multiplications.** Handle `b < 0` (error),
   `b = 0` (result 1, including `0 ^ 0`), `a = 0` (result 0) and `|a| = 1`
   (result ±1 by parity) directly. Otherwise use left-to-right binary
   exponentiation on magnitudes: start with `|a|`, and for each lower bit of
   `b` from the top square the accumulator and, if the bit is set, multiply
   it by `|a|`. Both steps use the general schoolbook multiply of item 7 (no
   dedicated squaring routine); multiplying by the short `|a|` costs only
   O(R·|a|). The sign is negative iff `a` is negative and `b` is odd. The
   cost is dominated by the last few squarings, about R²/3 limb products
   for a result of `R` limbs.
10. **Allocation.** Each arithmetic result gets one buffer sized for its
    maximum length up front (`max(n,m)+1` for addition, `n+m` for
    multiplication, `n−m+1` quotient limbs, one working copy of the dividend
    and divisor for division), filled by index and trimmed at the end. No
    allocation inside the inner loops of multiplication or division.

## Left to the implementer

- Container types (slices, vectors, lists, arrays), whether the sign is a flag
  or -1/0/1, struct or class layout, naming and module structure, and whether
  operations are free functions or methods.
- Exact digit-conversion code for parsing and printing a limb (lookup tables,
  hand-rolled loops or the standard formatter for a single zero-padded limb).
- Small loop-level optimisations: unrolling, pointer or index style,
  eliminating bounds checks, merging the first row of a product, using
  in-place helpers. These must not change the algorithms or their complexity
  above.
- Whether the line scan uses a library search for `\n` and spaces or a manual
  loop.

## Pitfalls

- Binary limbs (base 2³² or 2⁶⁴): decimal output then needs repeated division
  by 10⁹ over the whole number, quadratic in the length, and parsing needs a
  multiply-add over the whole number per chunk. With 100,000-digit results this
  dominates the run.
- Parsing by multiplying the running big number by 10 (or 10⁹) and adding,
  which is quadratic per operand.
- Single-digit (base 10) limbs: 81 times more inner-loop steps in
  multiplication and division than base 10⁹.
- A non-constant base or `%` and `/` with a runtime divisor in the inner loops,
  turning the carry split into a hardware divide on every limb.
- In the division multiply-subtract, subtracting the product's high part as
  the borrow and then repairing negative limbs with a loop of corrections;
  carry the product carry into the next product instead (item 8).
- Long division by repeated subtraction, bit-by-bit shift-and-subtract, or by
  binary searching each quotient limb with a full trial multiplication and
  comparison; each costs a factor of 30 or more over Algorithm D.
- Allocating a new array per quotient limb (a fresh `q̂·v` product, a fresh
  shifted dividend) instead of updating the working dividend in place.
- Computing `%` as `a − (a / b)·b`, which adds a full multiplication.
- Exponentiation by multiplying `b` times instead of binary exponentiation,
  or right-to-left square-and-multiply, which multiplies two large values for
  every set bit and does up to a quarter more limb work than left-to-right
  with a short base.
- Forgetting to trim most-significant zero limbs: comparisons by length go
  wrong and every later multiply runs on padding.
- Deep-copying an operand just to negate it for subtraction, or copying
  magnitudes when passing them between functions.
- Building the output by repeated string concatenation in a language where
  that copies the whole string each time, or writing and flushing each line
  separately.
- Using a language's built-in arbitrary-precision integer type for the values
  (SPEC.md forbids it). In a language whose only integer type is
  unbounded, limbs are plain integers kept below 2⁶³ and the unbounded type is
  used only as a machine word.
