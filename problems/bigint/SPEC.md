# bigint — Arbitrary-precision integer arithmetic

Implement signed arbitrary-precision integer arithmetic: addition, subtraction,
multiplication, truncating division, remainder, exponentiation and comparison
on decimal integers that may have tens of thousands of digits.

Write the arbitrary-precision arithmetic yourself: don't use an
arbitrary-precision integer type or routine from a library, the standard
library or the language (including a built-in unbounded integer type as the
number representation). Fixed-size machine integers are fine; where the
language's only integer type is unbounded, use it only for values that fit in
a machine word.

## Input

Standard input is UTF-8 text containing one query per line. Each line has the
form

    <a> <op> <b>

where the three tokens are separated by exactly one ASCII space and `op` is one
of

| op    | meaning                                   |
|-------|-------------------------------------------|
| `+`   | a + b                                     |
| `-`   | a - b                                     |
| `*`   | a * b                                     |
| `/`   | a / b, quotient truncated toward zero     |
| `%`   | a % b, remainder with the sign of a       |
| `^`   | a raised to the power b                   |
| `cmp` | three-way comparison of a and b           |

`a` and `b` are decimal integers matching the pattern `-?[0-9]+`:

- an optional leading `-`, then one or more ASCII digits `0`-`9`;
- no `+` sign, no spaces, no separators, no exponent notation;
- **leading zeros are allowed** in input (`007`, `-000123`);
- **negative zero forms are allowed** in input (`-0`, `-000`) and mean zero.

Lines are terminated by `\n` (never `\r\n`). The final line may or may not end
with a newline. There are no blank lines and no trailing spaces. Every line is a
well-formed query; you do not need to handle malformed input. The input may be
empty (zero queries); then print nothing.

## Output

Print exactly one line per input query, in input order, each terminated by
`\n`.

The result of `+ - * / % ^` is printed in **canonical decimal form**:

- no leading zeros (so zero is printed as `0`);
- a leading `-` if and only if the value is negative;
- **never `-0`**: zero is always printed as `0`, even when it results from
  e.g. `-5 * 0`, `-7 % 7`, `-1 / 2` or `-0 + 0`.

The result of `cmp` is `-1` if a < b, `0` if a = b, `1` if a > b (as numeric
values; `-0 cmp 0` is `0`, `007 cmp 7` is `0`).

### Division and remainder (C semantics)

`/` truncates toward zero and `%` is the remainder of that division, so for all
b ≠ 0:

    a == (a / b) * b + (a % b)
    |a % b| < |b|
    a % b is zero or has the same sign as a

Examples: `7 / 2 = 3`, `-7 / 2 = -3`, `7 / -2 = -3`, `-7 / -2 = 3`,
`7 % 2 = 1`, `-7 % 2 = -1`, `7 % -2 = 1`, `-7 % -2 = -1`, `-1 / 3 = 0`,
`-1 % 3 = -1`.

### Errors

If `b` is zero for `/` or `%` (including `0 / 0` and `0 % 0`), or if `b` is
negative (as a numeric value) for `^`, print the single line

    error

and continue with the next query. No other query produces an error. Zero is
never negative, so a `-0` or `-000` operand is not a negative exponent:
`5 ^ -0 = 1` and `-0 ^ -00 = 1`, while `5 / -0` is `error` because the divisor
is zero.

### Exponentiation

`a ^ b` with b ≥ 0 (b is given in the same `-?[0-9]+` form as every operand,
so it may carry leading zeros). `a ^ 0 = 1` for every a, **including
`0 ^ 0 = 1`**.
`0 ^ b = 0` for b > 0. The sign follows the usual rule: negative base with an
odd exponent gives a negative result, even exponent gives a positive result
(`-2 ^ 3 = -8`, `-2 ^ 2 = 4`, `-1 ^ 999 = -1`).

## Limits

- At most 10,000 queries per input; total input size at most 8 MB (at most 40 MB in the long benchmark tier, `bench-long/`).
- Operands have at most 50,000 digits excluding sign and leading zeros, and
  fewer than 100 leading zeros, so no operand token is longer than 50,101
  characters.
- For `^`, `0 ≤ b ≤ 5000` when it is not an error case, and the result has at
  most 100,000 digits. (A negative exponent is an error regardless of size.)
- Every non-error result has at most 100,000 digits.

Largest tests: a handful of products of two 50,000-digit numbers, a handful of
divisions of a 50,000-digit number by a 25,000-digit one, ~70 additions /
subtractions of 30,000- to 50,000-digit numbers, powers with results up to
100,000 digits, and one test of 10,000 small queries. Schoolbook O(n²)
multiplication and long division are sufficient if implemented with a large
limb base (e.g. base 10⁹ in 32-bit limbs or base 10¹⁸/2⁶⁴ in 64-bit limbs);
pure base-10 digit-at-a-time schoolbook multiplication is feasible but slow on
the largest test. Suggested timeout: 30 s per test (60 s for a naive implementation).
Output in one buffered write; converting a 100,000-digit result to decimal
must not be quadratic in a way that dominates (it is fine with base-10ⁿ limbs).

## Worked examples

### Example 1

Input:

```
12 + 30
5 - 7
-7 / 2
-7 % 2
```

Output:

```
42
-2
-3
-1
```

### Example 2

Input:

```
-0 + 0
007 cmp 7
-5 * 0
99999999999999999999 + 1
2 ^ 10
0 ^ 0
```

Output:

```
0
0
0
100000000000000000000
1024
1
```

### Example 3

Input:

```
1 / 0
0 % 0
2 ^ -1
-123456789012345678901234567890 * 987654321098765432109876543210
1000000000000000000000000000000 - 1
-3 cmp -2
```

Output:

```
error
error
error
-121932631137021795226185032733622923332237463801111263526900
999999999999999999999999999999
-1
```
