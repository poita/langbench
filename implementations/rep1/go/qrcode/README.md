# qrcode

A QR Code Model 2 (ISO/IEC 18004) encoder in Go, written from scratch using
only the standard library. It provides a reusable library and a small
command-line tool that prints symbols as text (`#` dark, `.` light).

Supported: versions 1–40, error-correction levels L/M/Q/H, numeric,
alphanumeric and byte modes (chosen automatically, one segment, no ECI
header), all eight masks, and automatic mask selection by penalty scoring.

## Build

Requires Go 1.27 or later.

```sh
./build.sh          # builds bin/qrcode
go test ./...       # runs the tests
```

## Command-line usage

`bin/qrcode` (or `./run.sh`) reads queries from standard input, one per line:

```
<ecl> <mask> <text>
```

* `<ecl>`: `L`, `M`, `Q` or `H`
* `<mask>`: `0`..`7`, or `auto` to pick the lowest-penalty mask
* `<text>`: the rest of the line, treated as UTF-8 bytes

For each query it prints `version <v> mask <m>`, the `4v+17` rows of the
symbol, and an empty line. No quiet zone is printed. A malformed query or one
that does not fit in version 40 makes the tool exit non-zero with a message on
stderr.

```console
$ echo "L auto 01234567" | ./run.sh
version 1 mask 3
#######.##..#.#######
...
```

## Library usage

```go
package main

import (
	"fmt"
	"log"

	"github.com/peteralexander/qrcode"
)

func main() {
	sym, err := qrcode.Encode("HELLO WORLD", qrcode.M, qrcode.AutoMask)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("version", sym.Version(), "mask", sym.Mask())
	for y := 0; y < sym.Size(); y++ {
		for x := 0; x < sym.Size(); x++ {
			if sym.Dark(x, y) {
				fmt.Print("██")
			} else {
				fmt.Print("  ")
			}
		}
		fmt.Println()
	}
}
```

Public API: `Encode`, `EncodeBytes`, `Symbol` (`Version`, `Level`, `Mask`,
`Size`, `Dark`, `String`), `Level` (`L`, `M`, `Q`, `H`), `Mode`, `SelectMode`,
`AutoMask`, `ErrTooLong`.

## Layout

| Path | Responsibility |
| --- | --- |
| `qrcode.go`, `doc.go` | public API |
| `segment.go` | mode selection, bit stream |
| `tables.go` | capacity / ECC / alignment tables |
| `codewords.go` | padding, block splitting, interleaving |
| `matrix.go` | function patterns, format/version info, data placement |
| `mask.go` | mask patterns and penalty scoring |
| `internal/reedsolomon` | GF(2^8) arithmetic and Reed-Solomon coding |
| `cmd/qrcode` | command-line tool |
