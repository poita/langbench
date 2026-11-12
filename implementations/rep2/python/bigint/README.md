# bigint

Arbitrary-precision signed integer arithmetic in pure Python, written from
scratch with the classical algorithms — no use of Python's unbounded `int` to
hold numbers (only machine-word-sized values pass through built-in ints).

- Numbers are a sign plus a magnitude of little-endian base-10⁹ limbs, so
  decimal parsing and printing are linear.
- `+`, `-`, comparison: linear.
- `*`: schoolbook long multiplication, O(n·m).
- `/`, `%`: Knuth's Algorithm D (quotient and remainder together),
  O((n − m + 1)·m), with truncating (C) semantics.
- `^`: binary exponentiation.

Only the standard library is used (plus `pytest` for the tests).

## Layout

```
pyproject.toml
build.sh / run.sh        build (byte-compile) and run the CLI
src/bigint/limbs.py      magnitude algorithms on limb lists
src/bigint/number.py     the signed BigInt class (public API)
src/bigint/cli.py        query-line command-line tool
tests/                   pytest suite
```

## Build

```
./build.sh
```

There is no install step; the project is pure Python. (`pip install .` also
works with the `pyproject.toml` and provides a `bigint` console script.)

## Command-line use

`run.sh` reads queries from standard input, one `<a> <op> <b>` per line, and
prints one result per line. `op` is one of `+ - * / % ^ cmp`.

```
$ printf '12 + 30\n-7 / 2\n-7 %% 2\n2 ^ 100\n007 cmp 7\n1 / 0\n' | ./run.sh
42
-3
-1
1267650600228229401496703205376
0
error
```

Operands match `-?[0-9]+` (leading zeros and `-0` accepted). Results are
canonical (no leading zeros, never `-0`). `/` and `%` by zero and `^` with a
negative exponent print `error`. `cmp` prints `-1`, `0` or `1`.

## Library use

```python
from bigint import BigInt

a = BigInt.parse("-123456789012345678901234567890")
b = BigInt.from_int(97)          # from_int only accepts machine-word values

print(a + b, a - b, a * b)
q, r = a.divmod_trunc(b)         # truncating division: a == q*b + r
print(q, r)                      # r has the sign of a
print(BigInt.parse("2") ** BigInt.parse("200"))
print(a.compare(b))              # -1
```

Division is truncating, unlike Python's `//` and `%`, so it is exposed as
`div_trunc`, `rem_trunc` and `divmod_trunc` instead of operators.
`divmod_trunc` raises `ZeroDivisionError` for a zero divisor; `pow` raises
`ValueError` for a negative exponent and `OverflowError` for an exponent
beyond a machine word when the base is not 0, 1 or -1.

## Tests

```
cd bigint && python3 -m pytest
```

The tests use Python's built-in `int` purely as an oracle to check results.
