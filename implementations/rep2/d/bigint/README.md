# bigint

Arbitrary-precision signed integer arithmetic in D, with no dependencies
beyond Phobos: a small library plus a command-line calculator built on it.

Numbers are a sign and a magnitude in base 10^9 (little-endian `uint` limbs), so
decimal parsing and printing are linear. Algorithms are the classical ones:

| operation     | algorithm                                              |
|---------------|--------------------------------------------------------|
| `+`, `-`, cmp | linear limb passes                                     |
| `*`           | schoolbook, O(n·m)                                     |
| `/`, `%`      | Knuth Algorithm D, quotient and remainder together     |
| `^`           | binary exponentiation (repeated squaring)              |

Division truncates toward zero and `%` takes the sign of the dividend.

## Layout

```
dub.sdl                  package manifest
source/bigint/package.d  `import bigint;` re-exports the public API
source/bigint/bigint.d   BigInt (signed), divMod, pow
source/bigint/natural.d  unsigned limb-array algorithms
source/bigint/decimal.d  decimal text <-> limbs
source/bigint/query.d    "<a> <op> <b>" evaluator
source/app.d             the CLI (thin wrapper over bigint.query)
build.sh, run.sh         build / run helpers
```

## Build

Requires LDC and dub.

```
./build.sh                       # same as: dub build -b release --compiler=ldc2
dub test --compiler=ldc2         # unit tests (D's built-in `unittest` blocks)
```

The default dub configuration is `cli` (the executable `./bigint`). Use the
`library` configuration when depending on the package.

## Command line

`./run.sh` (or `./bigint`) reads queries from standard input, one per line, and
prints one result per line:

```
$ printf '12 + 30\n-7 / 2\n-7 %% 2\n2 ^ 100\n007 cmp 7\n1 / 0\n' | ./run.sh
42
-3
-1
1267650600228229401496703205376
0
error
```

A line is `<a> <op> <b>` with `op` one of `+ - * / % ^ cmp`. Operands are
`-?[0-9]+`; leading zeros and `-0` are accepted. Results are canonical (no
leading zeros, never `-0`); `cmp` prints `-1`, `0` or `1`. Division or
remainder by zero and negative exponents print `error`. `0 ^ 0` is `1`.

## Library

```d
import std.stdio;
import bigint;

void main()
{
    auto a = BigInt("-123456789012345678901234567890");
    auto b = BigInt("987654321098765432109876543210");

    writeln(a * b);          // -121932631137021795226185032733622923332237463801111263526900
    writeln(BigInt(-7) / BigInt(2));   // -3  (truncating)
    writeln(BigInt(-7) % BigInt(2));   // -1  (sign of the dividend)
    writeln(BigInt(2) ^^ 100);         // 1267650600228229401496703205376

    BigInt q, r;
    divMod(a * b + BigInt(5), b, q, r);   // quotient and remainder together
    assert(q * b + r == a * b + BigInt(5));
}
```

Division by zero and negative exponents throw `BigIntException`; malformed
text throws `ParseException`.
