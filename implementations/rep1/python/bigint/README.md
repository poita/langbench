# bigint

Signed arbitrary-precision integer arithmetic in pure Python (standard library
only), written from scratch: addition, subtraction, multiplication, truncating
division, remainder, exponentiation and comparison on decimal integers with
tens of thousands of digits. Python's built-in unbounded `int` is **not** used
to represent numbers; limbs are base-10⁹ values that always fit in a 64-bit
word.

## Layout

| Module | Responsibility |
| --- | --- |
| `bigint.magnitude` | Unsigned algorithms on little-endian base-10⁹ limb lists: parse/print (linear), compare/add/subtract (linear), schoolbook multiplication, Knuth Algorithm D division, binary exponentiation |
| `bigint.integer` | `BigInt`, the signed immutable value type with operators |
| `bigint.queries` | Evaluates `<a> <op> <b>` query lines |
| `bigint.cli` / `__main__` | Thin stdin/stdout command-line wrapper |

## Build

There is nothing to compile. `./build.sh` byte-compiles the sources (a syntax
check). To install as a package: `pip install .` (setuptools, `pyproject.toml`).

## Command line

```
./run.sh < queries.txt          # or: PYTHONPATH=src python3 -m bigint < queries.txt
```

Each input line is `<a> <op> <b>` with `op` one of `+ - * / % ^ cmp`, operands
matching `-?[0-9]+` (leading zeros and `-0` allowed). One output line per
query: the result in canonical decimal form (never `-0`), `-1`/`0`/`1` for
`cmp`, or `error` for division/remainder by zero and negative exponents.
Division truncates toward zero and `%` takes the sign of the dividend.

```
$ printf '12 + 30\n-7 / 2\n-7 %% 2\n2 ^ 100\n1 / 0\n' | ./run.sh
42
-3
-1
1267650600228229401496703205376
error
```

## Library

```python
from bigint import BigInt, evaluate_query

a = BigInt.parse("-123456789012345678901234567890")
b = BigInt.parse("987654321098765432109876543210")
print(a * b)                  # -121932631137021795226185032733622923332237463801111263526900
print(a + b, a - b, a.compare(b))

q, r = a.divmod_trunc(BigInt.parse("1000000007"))   # C semantics: r has a's sign
print(q, r)
print(BigInt.parse("2") ** 200)                      # non-negative exponents only
print(evaluate_query("007 cmp 7"))                   # "0"
```

`BigInt` supports `+ - *`, unary `-`, `abs`, `**` (non-negative exponent;
`ValueError` otherwise), rich comparisons and hashing. Division is exposed as
`divmod_trunc`, `quotient` and `remainder` (truncating, unlike Python's `//`
and `%`) and raises `ZeroDivisionError` on a zero divisor. `BigInt.parse`
accepts `-?[0-9]+`; `BigInt.from_int` accepts machine-word ints only.

## Algorithms

Schoolbook O(n·m) multiplication (rows accumulated without carries, eight at a
time, then carry-propagated); Knuth's Algorithm D long division, computing
quotient and remainder together; binary exponentiation; no subquadratic
multiplication.

## Tests

```
pip install pytest
python3 -m pytest          # from this directory; configured in pyproject.toml
```

The unit tests use Python's native `int` purely as an oracle. The end-to-end
suite is run from the repository root with
`python3 run_tests.py bigint -- bigint/run.sh`.
