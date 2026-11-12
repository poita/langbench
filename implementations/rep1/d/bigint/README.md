# bigint

Signed arbitrary-precision integer arithmetic in D, with a small command-line
tool that evaluates one query per line. Only the D standard library is used;
the big-number arithmetic is implemented from scratch.

## Design

* A number is a sign plus a magnitude: little-endian `uint` limbs in base 10^9.
  Because the base is a power of ten, parsing and printing decimal text is
  linear (a binary base would make it quadratic).
* Add / subtract / compare: linear.
* Multiply: schoolbook, O(n·m).
* Divide / remainder: Knuth's Algorithm D (quotient and remainder together),
  O((n − m + 1)·m), one constant-time quotient-digit estimate per limb.
* Power: binary exponentiation (repeated squaring).
* Division truncates toward zero; the remainder has the sign of the dividend.
  Zero is never negative.

## Layout

| Path                         | Contents                                           |
|------------------------------|----------------------------------------------------|
| `source/bigint/bigint.d`     | `BigInt`, the public signed integer type           |
| `source/bigint/magnitude.d`  | unsigned limb-vector arithmetic (add, mul, divmod) |
| `source/bigint/decimal.d`    | decimal text <-> limbs                             |
| `source/bigint/exceptions.d` | exception types                                    |
| `source/bigint/query.d`      | evaluator for the `<a> <op> <b>` line protocol     |
| `source/bigint/package.d`    | `import bigint;` re-exports the public API         |
| `source/app.d`               | the command-line tool (thin wrapper over `query`)  |

## Build

Requires LDC and dub (developed with LDC 1.41.0 and dub 1.40.0).

```sh
./build.sh                                   # or: dub build -b release --compiler=ldc2
dub test --compiler=ldc2                     # run the unit tests
```

The executable is written to `bin/bigint`.

## Command-line usage

`bigint` (or `./run.sh`) reads queries from standard input, one per line, and
prints one result line per query:

```
<a> <op> <b>        op is one of  +  -  *  /  %  ^  cmp
```

Operands match `-?[0-9]+` (leading zeros and `-0` are accepted). Results are
canonical decimal (no leading zeros, never `-0`); `cmp` prints `-1`, `0` or `1`.
Division or remainder by zero and a negative exponent print `error`.

```console
$ printf '12 + 30\n-7 / 2\n-7 %% 2\n2 ^ 100\n1 / 0\n007 cmp 7\n' | ./run.sh
42
-3
-1
1267650600228229401496703205376
error
0
```

A malformed line makes the tool print a message to stderr and exit with status 1.

## Library usage

Add it as a dependency (`dependency "bigint" path="../bigint"`; dub picks the
`library` configuration automatically) and:

```d
import bigint;
import std.stdio;

void main()
{
    auto a = BigInt("-123456789012345678901234567890");
    auto b = BigInt(987654321);

    writeln(a * b);                 // -121932631124828532112482853211126352690
    writeln(a / b, " ", a % b);     // truncating division, remainder has a's sign
    writeln(BigInt(2) ^^ BigInt(100));
    writeln(a < b);                 // true

    BigInt q, r;
    BigInt.divMod(a, b, q, r);      // quotient and remainder in one pass
    assert(q * b + r == a);

    try
        BigInt(1) / BigInt(0);
    catch (DivisionByZeroException e)
        writeln("error: ", e.msg);
}
```

Operations: `+ - * / % ^^`, unary `-`, comparison, `BigInt.pow`, `BigInt.divMod`,
`abs`, `sign`, `isZero`, `isNegative`, `toString`, and construction from
`long` or decimal text (`ParseException` on invalid text).

## Tests

The tests are D `unittest` blocks next to the code (edge cases, the examples
from the specification, and randomised identity checks such as
`q*b + r == a`), run with `dub test --compiler=ldc2`.
