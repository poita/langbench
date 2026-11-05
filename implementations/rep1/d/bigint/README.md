# bigint

Signed arbitrary-precision integer arithmetic in D, written from scratch on the
standard library only. Values are sign + magnitude; magnitudes are little-endian
arrays of base-10⁹ limbs (`uint`), so decimal parsing and printing are linear.
It supports `+ - * / % ^` and three-way comparison, with C-style truncating
division, and ships with a small line-oriented calculator CLI.

Algorithms are the classical quadratic ones: schoolbook multiplication, short
division and Knuth's Algorithm D for long division, and left-to-right binary
exponentiation.

## Layout

```
dub.json                  package manifest (configurations: cli, library, unittest)
source/bigint/
  package.d               re-exports the public API
  magnitude.d             unsigned limb-array kernels: compare, add, sub, mul, divMod, pow
  decimal.d               linear-time parse / format of decimal text
  integer.d               the signed BigInt type with operators
  queries.d               evaluator for the "<a> <op> <b>" query language
cli/app.d                 thin CLI: stdin -> evaluateQueries -> stdout
tests/                    unit tests (separate from the library source)
build.sh, run.sh          build / run helpers
```

## Build and test

Requires LDC 1.41 and dub 1.40.

```
./build.sh                          # dub build -b release --compiler=ldc2 --config=cli -> bin/bigint
dub test --compiler=ldc2            # unit tests
```

## CLI

`./run.sh` reads queries from standard input, one per line, and writes one
result line per query.

```
<a> <op> <b>        op is one of  +  -  *  /  %  ^  cmp
```

Operands match `-?[0-9]+` (leading zeros and `-0` allowed). Results are in
canonical decimal form (never `-0`); `cmp` prints `-1`, `0` or `1`. Division or
remainder by zero, and a negative exponent, print `error`. `/` truncates toward
zero and `%` takes the sign of the dividend. `0 ^ 0 = 1`.

```
$ printf '12 + 30\n-7 / 2\n-7 %% 2\n2 ^ 100\n1 / 0\n' | ./run.sh
42
-3
-1
1267650600228229401496703205376
error
```

## Library example

```d
import std.stdio : writeln;
import bigint;

void main()
{
    auto a = BigInt("123456789012345678901234567890");
    auto b = BigInt("-987654321098765432109876543210");

    writeln(a + b);              // -864197532086419753208641975320
    writeln(a * b);
    writeln(b / a, " ", b % a);  // truncating division, remainder has b's sign
    writeln(pow(BigInt(2), BigInt(100)));
    writeln(a < b);              // false

    auto q = divMod(b, a);       // [quotient, remainder] in one call
}
```

Use it from another dub project with `"dependencies": { "bigint": { "path": "../bigint" } }`
and `"subConfigurations": { "bigint": "library" }`.

Errors in the `BigInt` API (division by zero, negative exponent, malformed
text) throw `Exception`. The bulk query evaluator `evaluateQueries` instead
reports them as `error` lines.

## Notes

`evaluateQueries` interprets exponents modulo 2⁶⁴ when folding to a machine
integer; the specification limits valid exponents to 5000, so this only matters
for inputs outside the contract.
