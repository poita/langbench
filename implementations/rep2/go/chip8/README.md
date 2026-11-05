# chip8

A deterministic CHIP-8 interpreter in Go: a reusable library plus a thin
command-line tool. It implements the fixed CHIP-8 variant defined in the
project's `SPEC.md` (in-place shifts, wrapping sprites, a timer tick every 8
cycles, and a built-in LCG random generator). Standard library only.

## Build

```
./build.sh          # produces bin/chip8
go test ./...       # unit tests
```

## CLI

`./run.sh` reads all of stdin and writes the result to stdout:

```
<rom-hex>
<cycles>
<key-schedule>      (optional: "<cycle>:<mask-hex4>" events separated by spaces)
```

It runs exactly `<cycles>` instruction cycles and prints 32 display rows
(`#`/`.`), then a `PC=… I=… SP=… DT=… ST=…` line and a `V=…` register line.

```
$ printf '60ff7001610180141208\n6\n' | ./run.sh | tail -2
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

## Library

Package `github.com/example/chip8`, split by responsibility:

| File | Contents |
|------|----------|
| `font.go` | font data and memory layout constants |
| `display.go` | `Display`: 32 rows of 64-bit words, rotate-based sprite XOR |
| `rng.go` | `NextRNG`, the `CXNN` generator |
| `machine.go` | `Machine`, `New`, `LoadROM`, `Run`, `Step` |
| `input.go` | `ParseInput`, `ParseHexROM`, `ParseSchedule`, `KeyEvent` |
| `output.go` | `Machine.Format`, the 34-line text output |

Example:

```go
package main

import (
	"fmt"

	"github.com/example/chip8"
)

func main() {
	rom, _ := chip8.ParseHexROM("6a3e6b1e6000f029dab5") // draw glyph "0" at (62,30)
	m := chip8.New()
	if err := m.LoadROM(rom); err != nil {
		panic(err)
	}
	// Hold key 3 from cycle 2 onward.
	m.Run(5, []chip8.KeyEvent{{Cycle: 2, Mask: 1 << 3}})
	fmt.Printf("PC=%04x VF=%d pixel(62,30)=%v\n", m.PC, m.V[0xF], m.Display.Pixel(62, 30))
	fmt.Print(string(m.Format()))
}
```

`Run` keeps the program counter, registers and timers in locals for the
duration of the loop and dispatches on the top nibble of each opcode with a
single `switch`; nothing is pre-decoded, so self-modifying code works.
