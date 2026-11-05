# bigint

Arbitrary-precision signed integer arithmetic in pure D (standard library only).
Supports `+`, `-`, `*`, truncating `/` and `%`, `^` (exponentiation) and
three-way comparison on integers with tens of thousands of digits.

Numbers are stored as sign + magnitude; the magnitude is a little-endian array of
base-10⁹ limbs (`uint`), so parsing and printing decimal are linear. Algorithms
are the classical quadratic ones: schoolbook multiplication, short division and
Knuth's Algorithm D for long division, and left-to-right binary exponentiation.
No built-in or library big-integer type is used.

## Layout

| Path                    | Purpose                                                     |
|-------------------------|-------------------------------------------------------------|
| `source/bigint/limbs.d`   | unsigned magnitude algorithms (add, sub, mul, divmod, parse, print) |
| `source/bigint/integer.d` | the signed `BigInt` type, `divMod`, `pow`                   |
| `source/bigint/queries.d` | evaluator for the `<a> <op> <b>` line format                |
| `source/bigint/package.d` | `import bigint;` re-exports everything                      |
| `app/main.d`              | thin command-line tool                                      |
| `tests/`                  | unit tests (run with `dub test`)                            |

## Build

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh          # dub build -b release --compiler=ldc2 --config=cli
dub test --compiler=ldc2
```

The default dub configuration is `cli` (executable `bigint-cli`). Depend on the
`library` configuration when using it as a package, e.g. in `dub.sdl`:

```
dependency "bigint" path="../bigint"
subConfiguration "bigint" "library"
```

## Command-line use

`./run.sh` reads queries from standard input, one per line, and writes one result
line per query to standard output:

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
`-?[0-9]+` (leading zeros and `-0` allowed). Results are canonical (no leading
zeros, never `-0`). `cmp` prints `-1`, `0` or `1`. Division or remainder by zero
and a negative exponent print `error`. Input is read in one bulk read and the
output is written in one write. Malformed input makes the tool exit with status 1.

## Library use

```d
import std.stdio;
import bigint;

void main()
{
    auto a = BigInt("123456789012345678901234567890");
    auto b = BigInt("-987654321");

    writeln(a * b);                 // product
    writeln(a + b, " ", a - b);
    auto qr = divMod(a, b);         // truncating: a == q*b + r, r has the sign of a
    writeln(qr.quotient, " ", qr.remainder);
    writeln(pow(BigInt(2), 100));   // 1267650600228229401496703205376
    writeln(a < b, " ", a == BigInt("0123456789012345678901234567890"));
}
```

Division by zero throws `BigIntException`. Values are never mutated by
operations, so copies share their magnitude storage cheaply.
