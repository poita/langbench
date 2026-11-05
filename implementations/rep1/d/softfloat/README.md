# softfloat

Software IEEE-754 binary32 (single-precision) arithmetic in D: add, subtract,
multiply, divide and square root on raw 32-bit patterns, with
round-to-nearest-even and full gradual underflow. Everything is computed with
integer operations on at most 64-bit words — no host floating point, no wide
integers — and the NaN policy is simple: any NaN operand or invalid operation
gives the canonical quiet NaN `7fc00000`.

## Layout

| Path | Purpose |
| --- | --- |
| `source/softfloat/bits.d` | field masks, classification, unpacking to `m * 2^e` |
| `source/softfloat/round.d` | `roundPack`, the one shared rounding routine |
| `source/softfloat/arith.d` | `add`, `sub`, `mul`, `div`, `sqrt` |
| `source/softfloat/io.d` | line-oriented batch format (`processBatch`) |
| `source/softfloat/package.d` | `import softfloat;` re-exports everything |
| `app/main.d` | the command-line tool |
| `tests/softfloat/` | unit tests (kept apart from the library) |

## Build

Requires LDC and dub.

```sh
./build.sh                                   # same as: dub build -b release --compiler=ldc2
dub test --compiler=ldc2                     # unit tests
```

## CLI

The tool reads operations from standard input, one per line, and writes one
result line per input line:

```
<op> <a> <b>     op in add sub mul div
sqrt <a>
```

Operands are 8 lowercase hex digits (the binary32 bit pattern); results are 8
lowercase hex digits.

```sh
$ printf 'add 3f800000 3f800000\ndiv 3f800000 40400000\nsqrt 40000000\n' | ./run.sh
40000000
3eaaaaab
3fb504f3
```

## Library

Add it as a dub dependency (path or registry) and use the `softfloat` package:

```d
import softfloat;

void main()
{
    assert(add(0x3f800000, 0x3f800000) == 0x40000000); // 1 + 1 == 2
    assert(div(0x3f800000, 0x40400000) == 0x3eaaaaab); // 1 / 3
    assert(sqrt(0x40000000) == 0x3fb504f3);            // sqrt(2)
    assert(mul(0x7f800000, 0) == canonicalNaN);        // inf * 0 is invalid

    // The batch format used by the CLI:
    auto out_ = processBatch(cast(const(ubyte)[]) "sub 40000000 3f800000\n");
    assert(cast(string) out_ == "3f800000\n");
}
```

## Design notes

* `add`/`sub` align the smaller operand against 35 guard bits and fold lost
  bits into a sticky flag; `sub a b` is `add a (-b)`.
* `mul` is one exact 24×24→48-bit product.
* `div` is one 64-bit integer division with a 32-bit scaled dividend; the
  remainder gives the sticky bit.
* `sqrt` is the digit-by-digit restoring integer square root.
* All paths end in `roundPack`, which rounds exactly once on the final
  (normal or denormal) grid, so there is no double rounding.

The unit tests cross-check the library against the host FPU on random inputs;
the FPU is used there only as an oracle, never by the library.
