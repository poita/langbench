# qrcode

A from-scratch QR Code Model 2 (ISO/IEC 18004) encoder in Go, using only the
standard library. It consists of a reusable library (`qr`) and a thin
command-line tool (`cmd/qrcode`) that prints symbols as text.

Supported: numeric, alphanumeric and byte modes (single segment, no ECI),
versions 1–40, error correction levels L/M/Q/H, mask patterns 0–7 and
automatic mask selection by the standard penalty rules.

## Build

Requires Go 1.27 or newer.

    ./build.sh          # builds bin/qrcode
    go test ./...       # unit tests

## Command-line use

`run.sh` reads queries from standard input, one per line:

    <ecl> <mask> <text>

`ecl` is `L`, `M`, `Q` or `H`; `mask` is `0`..`7` or `auto`; `text` is the rest
of the line (arbitrary UTF-8, treated as bytes). For each query it prints

    version <v> mask <m>
    <size rows of '#' (dark) and '.' (light)>
    <blank line>

Example:

    $ echo 'L auto 01234567' | ./run.sh
    version 1 mask 3
    #######.##..#.#######
    ...

Malformed or oversized queries make the program print an error to stderr
(after the output of the preceding queries) and exit with status 1.

## Library use

```go
package main

import (
	"fmt"
	"log"

	"github.com/example/qrcode/qr"
)

func main() {
	sym, err := qr.EncodeString("HELLO WORLD", qr.M, qr.AutoMask)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("version", sym.Version, "mask", sym.Mask)
	for y := 0; y < sym.Size(); y++ {
		for x := 0; x < sym.Size(); x++ {
			if sym.Dark(x, y) {
				fmt.Print("##")
			} else {
				fmt.Print("  ")
			}
		}
		fmt.Println()
	}
}
```

Public API: `Encode`, `EncodeString`, `Symbol` (`Size`, `Dark`, `AppendRows`,
`String`), `ECL` (`L`, `M`, `Q`, `H`), `ParseECL`, `ParseMask`, `AutoMask`,
`SelectMode`, and the errors `ErrEmpty`, `ErrTooLong`, `ErrBadECL`,
`ErrBadMask`.

## Layout

    qr/gf.go         GF(2^8) log/antilog arithmetic
    qr/rs.go         Reed-Solomon generator and remainder
    qr/bitwriter.go  MSB-first bit packing
    qr/tables.go     capacity, block and alignment tables
    qr/segment.go    mode and version selection
    qr/codewords.go  data codewords, ECC, interleaving
    qr/matrix.go     function patterns, placement, format/version info
    qr/mask.go       mask patterns
    qr/penalty.go    penalty scoring (N1–N4)
    qr/encode.go     public API
    cmd/qrcode       command-line tool
