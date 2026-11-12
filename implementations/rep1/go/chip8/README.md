# chip8

A small, deterministic CHIP-8 interpreter written in Go, with no dependencies
beyond the standard library. It is both a reusable library (package `chip8`)
and a command-line tool that runs a ROM for an exact number of cycles and
prints the final display and CPU state.

The behaviour is fully specified (shift semantics, `FX55`/`FX65`, `BNNN`,
sprite wrapping, timer rate, a built-in LCG random generator), so runs are
reproducible bit for bit.

## Layout

| File | Responsibility |
|------|----------------|
| `machine.go` | `Machine` state, `New`, `Step`, `Run`, report formatting |
| `cpu.go` | instruction decode and execution |
| `display.go` | 64x32 frame buffer and XOR sprite drawing |
| `keys.go` | key events and schedules |
| `rng.go` | the specified 32-bit LCG |
| `font.go` | built-in font and memory-layout constants |
| `input.go` | parsing of the textual input format |
| `cmd/chip8` | the command-line tool |

Every cycle fetches and decodes the opcode from memory (no pre-decoding or
caching), so self-modifying programs work.

## Build

```sh
./build.sh          # produces bin/chip8   (runs: go build -o bin/chip8 ./cmd/chip8)
go test ./...       # run the tests
```

## CLI

`./run.sh` (or `bin/chip8`) reads three lines from stdin:

```
<rom-hex>         ROM bytes, lowercase hex, loaded at 0x200
<cycles>          number of cycles to execute (0..4000000000)
<key-schedule>    optional: space-separated <cycle>:<mask> events (mask = 4 hex digits, bit k = key k held)
```

and writes 34 lines: the 32 display rows (`#` lit, `.` unlit), a
`PC=.... I=.... SP=n DT=.. ST=..` line and a `V=..  ..` register line.

```sh
$ printf '60ff7001610180141208\n6\n' | ./run.sh | tail -2
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

The tool exits 0 on success and non-zero (with a message on stderr) on
malformed input.

## Library example

```go
package main

import (
	"fmt"

	"github.com/example/chip8"
)

func main() {
	// V0 = 5; I = glyph for V0; draw it at (V1, V2) = (0, 0); loop forever.
	rom := []byte{0x60, 0x05, 0xF0, 0x29, 0xD1, 0x25, 0x12, 0x06}
	m, err := chip8.New(rom)
	if err != nil {
		panic(err)
	}
	// Hold key 3 from cycle 100 on.
	m.Run(200, chip8.KeySchedule{{Cycle: 100, Mask: 1 << 3}})
	fmt.Print(m.Report())
	fmt.Println(m.V[0], m.Display.Pixel(0, 0))
}
```

Use `chip8.ParseProgram` to read the CLI's input format, `Machine.Step` to
single-step, and the exported `Machine` fields (`V`, `I`, `PC`, `Mem`,
`Display`, ...) to inspect state.

Pushing onto a full stack and returning from an empty one are unspecified by
the spec; this implementation ignores the stack access (no panic).
