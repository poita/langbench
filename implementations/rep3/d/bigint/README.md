# bigint

Signed arbitrary-precision integer arithmetic in D, with no dependencies beyond
the D standard library. Values are a sign plus a little-endian magnitude of
base-10⁹ limbs (stored as `uint`, products computed in 64 bits), so parsing and
printing decimal text is linear time. The algorithms are the classical
quadratic ones: schoolbook multiplication, Knuth's Algorithm D for division,
and left-to-right binary exponentiation.

The project has two parts:

* a library (`source/bigint/`) with a documented public API;
* a thin command-line tool (`app/main.d`) that evaluates one `<a> <op> <b>`
  query per input line.

| Module | Contents |
|---|---|
| `bigint` | `package.d`; imports everything below |
| `bigint.integer` | `BigInt` (operators, comparison, `divMod`, `pow`) |
| `bigint.magnitude` | unsigned limb arrays: `addMag`, `subMag`, `mulMag`, `cmpMag` |
| `bigint.division` | `divModLimb`, `divModMag` (Algorithm D) |
| `bigint.decimal` | `parseMagnitude`, `formatMagnitude`, `decimalLength` |

## Build

Requires LDC and dub (developed with LDC 1.41.0 and dub 1.40.0).

```
./build.sh          # dub build -b release --compiler=ldc2  ->  bin/bigint
dub test --compiler=ldc2
```

## Command-line use

`run.sh` reads queries on stdin and writes one result line per query to stdout:

```
$ printf '12 + 30\n-7 / 2\n-7 %% 2\n2 ^ 100\n007 cmp 7\n1 / 0\n' | ./run.sh
42
-3
-1
1267650600228229401496703205376
0
error
```

Each line is `<a> <op> <b>` with `op` one of `+ - * / % ^ cmp`; operands match
`-?[0-9]+` (leading zeros and `-0` are accepted). Division truncates toward
zero and `%` takes the sign of the dividend. Division by zero and a negative
exponent print `error`. Results are canonical decimal (never `-0`); `cmp`
prints `-1`, `0` or `1`.

## Library example

Use the library from another dub project by adding this directory as a path
dependency and selecting the `library` configuration:

```
dependency "bigint" path="../bigint"
subConfiguration "bigint" "library"
```

```d
import std.stdio;
import bigint;

void main()
{
    auto a = BigInt("123456789012345678901234567890");
    auto b = BigInt("-987654321");

    writeln(a + b);           // 123456789012345678900246913569
    writeln(a * b);
    writeln(a / b);           // -124999998873437499901 (truncating)
    writeln(a % b);           // sign follows the dividend

    BigInt q, r;
    divMod(a, b, q, r);       // one call gives quotient and remainder
    assert(q * b + r == a);

    writeln(BigInt(2) ^^ 100); // 1267650600228229401496703205376
    writeln(a < b);            // false
}
```

`BigInt` throws `BigIntException` on division by zero, and the string
constructor throws `Exception` on malformed input.

## Layout

```
dub.sdl       manifest (configurations: cli, library, unittest)
build.sh      builds bin/bigint
run.sh        runs bin/bigint
source/       the library
app/main.d    the command-line tool
tests/        unit tests (compiled only by `dub test`)
```
