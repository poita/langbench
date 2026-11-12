# softfloat

IEEE-754 binary32 (single precision) arithmetic in pure integer Go: add,
subtract, multiply, divide and square root, with round-to-nearest-even and full
gradual underflow. Values are raw 32-bit patterns, so every output bit is
exact. No host floating point is used; only the standard library is required.

## Layout

| Path                | Purpose                                                   |
|---------------------|-----------------------------------------------------------|
| `float32.go`        | bit-field constants, classification, unpacking            |
| `round.go`          | the single shared round-and-pack step, sticky-shift helper |
| `add.go` `mul.go` `div.go` `sqrt.go` | the operations                           |
| `op.go`             | `Op` enum and `Apply` dispatcher                          |
| `batch/`            | line-oriented script evaluation (parsing/formatting)      |
| `cmd/softfloat/`    | the command-line tool                                     |

Each operation produces a truncated integer result plus a sticky bit (all
intermediates fit in 64 bits); `roundPack` rounds once, directly onto the
normal or denormal grid. Division is one integer divide; square root is the
restoring digit-by-digit method.

## Build and test

    ./build.sh          # produces bin/softfloat
    go test ./...       # add -short for a quicker run

Requires Go 1.27.1. The tests compare against the hardware `float32` type as an
oracle (tests only; the library never uses it).

## CLI

    ./run.sh < input.txt

Input: one operation per line, `add|sub|mul|div <a> <b>` or `sqrt <a>`, with
operands as 8 lowercase hex digits (the binary32 bit pattern). Output: one
8-digit lowercase hex result per line. Any NaN operand or invalid operation
gives the canonical quiet NaN `7fc00000`. A malformed line prints an error to
stderr and exits nonzero.

    $ printf 'div 3f800000 40400000\nsqrt 40000000\n' | ./run.sh
    3eaaaaab
    3fb504f3

## Library

```go
package main

import (
	"fmt"

	"softfloat"
)

func main() {
	one, three := uint32(0x3f800000), uint32(0x40400000)
	fmt.Printf("%08x\n", softfloat.Div(one, three))   // 3eaaaaab
	fmt.Printf("%08x\n", softfloat.Sqrt(0x40000000))  // 3fb504f3
	fmt.Printf("%08x\n", softfloat.Apply(softfloat.OpAdd, one, one)) // 40000000
}
```

Functions: `Add`, `Sub`, `Mul`, `Div`, `Sqrt`, `Neg`, `IsNaN`, `IsInf`,
`IsZero`, `Apply`, `ParseOp`. The module path is `softfloat`; use it from
another module with a `replace` directive or `go.work`.
