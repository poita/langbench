# bigint: required approach

SPEC.md defines what the program does; this note defines how it computes it.
Where the two seem to disagree, SPEC.md wins.

Sizes: `n` and `m` are the operands' lengths in digits (up to 50,000).

## Algorithm

Each operand is held as a sign and a magnitude, the magnitude a sequence of
digits in a large base, and each query is evaluated with the classical
algorithms:

- **Parsing and printing:** linear in the number of decimal digits. (This rules
  out a binary base, whose decimal conversion is quadratic.)
- **Comparison, addition and subtraction:** linear, O(n + m).
- **Multiplication:** schoolbook long multiplication, O(n·m). No Karatsuba,
  Toom-Cook, FFT or other subquadratic method.
- **Division and remainder:** long division that produces each quotient digit
  in constant time from an estimate (Knuth's Algorithm D), O((n − m + 1)·m), with
  the quotient and remainder computed together. No repeated subtraction,
  bit-by-bit division or search for each quotient digit.
- **Exponentiation:** binary exponentiation (repeated squaring), O(log b)
  multiplications, each by the schoolbook method.
