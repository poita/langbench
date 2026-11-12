# softfloat

Software IEEE-754 binary32 (single-precision) arithmetic in D: addition,
subtraction, multiplication, division and square root, with
round-to-nearest-even and full gradual underflow (denormals).  Everything is
computed with 64-bit integer operations on raw bit patterns; no hardware
floating point, `float` conversions, `std.math` or big-integer types are used.

The project has two parts:

* a reusable library (`source/softfloat/`), and
* a thin command-line tool (`app/main.d`) that reads operations from standard
  input and prints result bit patterns.

## Layout

| Module                | Responsibility                                              |
|-----------------------|-------------------------------------------------------------|
| `softfloat.bits`      | bit-field access, classification, unpacking to `m * 2^e`     |
| `softfloat.rounding`  | shift-with-sticky and the single shared round-and-pack step  |
| `softfloat.addsub`    | `add`, `sub` (guard-bit alignment, sticky folding)          |
| `softfloat.mul`       | `mul` (exact 48-bit product)                                 |
| `softfloat.div`       | `div` (one integer divide, remainder is the sticky bit)      |
| `softfloat.sqrt`      | `sqrt` (restoring digit-by-digit integer square root)        |
| `softfloat.ops`       | `Float32`, a value type with operator overloads              |
| `softfloat.text`      | the line-based hex text protocol used by the CLI             |
| `softfloat`           | `package.d`, imports everything above                        |

## Build

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh          # same as: dub build -b release --compiler=ldc2
```

This produces `bin/softfloat`.  `dub build -c library` builds only the library.

## Test

```sh
dub test --compiler=ldc2
```

The tests are D `unittest` blocks next to the code, plus property and
regression tests in `source/softfloat/tests.d`.

## Command line

```sh
./run.sh < ops.txt > results.txt
```

Input is one operation per line, `<op> <a> <b>` for `add sub mul div` or
`<op> <a>` for `sqrt`.  Operands are exactly eight lowercase hex digits giving
the binary32 bit pattern.  Output is one line per input line: the result as
eight lowercase hex digits.  Any NaN result is the canonical `7fc00000`.

```console
$ printf 'add 3f800000 3f800000\ndiv 3f800000 40400000\nsqrt 40000000\n' | ./run.sh
40000000
3eaaaaab
3fb504f3
```

Malformed input makes the tool print a message to stderr and exit with status 1.

## Library example

```d
import softfloat;

void main()
{
    // Raw bit patterns: 1.0 and 3.0.
    uint one = 0x3f80_0000, three = 0x4040_0000;

    assert(softfloat.addsub.add(one, one) == 0x4000_0000);   // 1 + 1 = 2
    assert(softfloat.div.div(one, three) == 0x3eaa_aaab);    // 1 / 3, rounded

    // Or use the value type with operators.
    auto x = Float32(0x4000_0000);                           // 2.0
    assert(x.sqrt.bits == 0x3fb5_04f3);                      // sqrt(2)
    assert((Float32(0x7f80_0000) - Float32(0x7f80_0000)).isNaN);

    // Text protocol helpers.
    assert(evaluateLine("mul 40400000 c0400000") == 0xc110_0000); // 3 * -3 = -9
}
```

Note: `div` and `sqrt` are also names in `std.math`/`std.algorithm`; qualify
them (`softfloat.div.div`) or import selectively when mixing.

## How it works

Every operation reduces its operands to an integer significand and exponent,
computes a truncated integer result plus a sticky bit, and passes it to
`roundPack`, which rounds once, to nearest-even, directly onto the binary32
grid (normal or denormal).  All intermediates fit in 64 bits.
Division is a single integer divide; square root is the restoring
digit-by-digit method (about 31 steps).
