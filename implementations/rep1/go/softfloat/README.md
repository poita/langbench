# softfloat

A software implementation of IEEE-754 binary32 (single-precision) arithmetic in
Go: add, subtract, multiply, divide and square root, with round-to-nearest-even
and full gradual underflow (denormals). Everything is computed with integer
operations on a single 64-bit word plus a sticky bit — no hardware floating
point, no `math.Sqrt`, standard library only (`math/bits` for bit-length).

Values are exchanged as raw 32-bit patterns (`uint32`), so every bit of every
result is well defined. Any NaN operand and every invalid operation yields the
canonical quiet NaN `0x7fc00000`. Exceptions and flags are not modelled.

## Layout

| Path | Responsibility |
| --- | --- |
| `doc.go`, `bits.go` | package docs, constants, classification, operand unpacking |
| `round.go` | `roundPack`: the one shared single-rounding routine (normal + denormal) |
| `add.go`, `mul.go`, `div.go`, `sqrt.go` | the arithmetic operations |
| `op.go` | `Op` enum, `ParseOp`, `Eval` dispatch |
| `internal/batch` | text protocol: parsing lines, hex formatting |
| `cmd/softfloat` | the command-line tool |

## Build

Requires Go 1.27.1.

    ./build.sh          # produces bin/softfloat
    go test ./...       # unit tests (add -short for a quicker run)

## Command-line usage

The tool reads operations from standard input, one per line, and prints one
8-digit lowercase hex result per line:

    $ printf 'add 3f800000 3f800000\ndiv 3f800000 40400000\nsqrt 40000000\n' | ./run.sh
    40000000
    3eaaaaab
    3fb504f3

Line format: `<op> <a> <b>` for `add sub mul div`, `sqrt <a>` for square root;
operands are 8 hex digits (the binary32 bit pattern). The program exits
non-zero (after printing results for the preceding lines) on a malformed line.

## Library usage

```go
package main

import (
	"fmt"

	"softfloat"
)

func main() {
	one, three := uint32(0x3f800000), uint32(0x40400000)
	fmt.Printf("%08x\n", softfloat.Div(one, three))       // 3eaaaaab
	fmt.Printf("%08x\n", softfloat.Sqrt(0x40000000))      // 3fb504f3
	fmt.Printf("%08x\n", softfloat.Add(0x7f800000, 0xff800000)) // 7fc00000 (inf - inf)

	op, _ := softfloat.ParseOp("mul")
	fmt.Printf("%08x\n", softfloat.Eval(op, three, 0xc0400000)) // c1100000 (3 * -3)
}
```

The public API: `Add`, `Sub`, `Mul`, `Div`, `Sqrt`, `Neg`, `IsNaN`, `IsInf`,
`IsZero`, the constants `QNaN`, `PosInf`, `NegInf`, and `Op`/`ParseOp`/`Eval`.

## Design notes

* Special values (NaN, infinity, zero) are resolved from the bit fields first;
  only finite nonzero operands reach the arithmetic.
* Operands unpack to `(m, e)` with value `m·2^e` on the 2^-149 grid.
* `add` aligns with 32 guard bits and folds shifted-out bits into a sticky flag;
  `mul` is an exact 24×24→48-bit product; `div` is one 64-bit divide of the
  normalised significands shifted left by 32; `sqrt` is a digit-by-digit
  integer root of the scaled significand.
* `roundPack` rounds exactly once onto the destination grid (normal or
  denormal), so there is no double rounding; a carry out of the significand
  ripples naturally into the exponent field (including denormal → smallest
  normal and overflow → infinity).

## Testing note

The unit tests use the host's `float32` arithmetic as an independent oracle
for randomised comparison; the library itself never does.
