# chip8

A small, deterministic CHIP-8 interpreter written in Go, using only the
standard library. It is a reusable library (`github.com/example/chip8`) plus a
thin command-line tool that reads a ROM, a cycle budget and an optional key
schedule, runs the machine for exactly that many cycles, and prints the
64x32 display and CPU state.

The machine implements a fully specified variant of CHIP-8 (in-place shifts,
`FX55`/`FX65` leave `I` unchanged, `BNNN` always uses `V0`, sprites wrap on both
axes, timers tick every 8 cycles, fixed LCG random numbers) so that every run
is reproducible.

## Layout

| File | Responsibility |
|------|----------------|
| `machine.go` | `Machine` state, font, ROM loading |
| `run.go` | the fetch-decode-execute loop, `KeyEvent` |
| `display.go` | `Display`: 32 rows of 64-bit words, pixel helpers |
| `input.go` | parsing the textual input format (`ParseInput`) |
| `output.go` | rendering the 34-line report |
| `cmd/chip8` | the command-line tool |

## Build

```
./build.sh          # or: go build -o bin/chip8 ./cmd/chip8
go test ./...       # unit tests
```

Requires Go 1.27 or newer; no third-party dependencies.

## Command-line usage

`chip8` (or `./run.sh`) reads all of stdin and writes to stdout:

```
<rom-hex>             ROM bytes, lowercase hex, 1..3584 bytes
<cycles>              0..4000000000
<key-schedule>        optional: space-separated <cycle>:<mask> events
```

The ROM is loaded at `0x200`. A key event `c:mask` takes effect immediately
before cycle `c`; bit `k` of the 4-digit hex mask means key `k` is held.

Output is 34 lines: 32 display rows of `#`/`.`, then
`PC=.... I=.... SP=n DT=.. ST=..`, then `V=` followed by `V0`..`VF`.

```
$ printf '60ff7001610180141208\n6\n' | ./run.sh | tail -2
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Malformed input prints a message to stderr and exits with status 1.

## Library example

```go
package main

import (
	"fmt"
	"os"

	"github.com/example/chip8"
)

func main() {
	// V0 = 5; I = font glyph for V0; draw it at (V1, V2) = (0, 0); loop.
	rom := []byte{0x60, 0x05, 0xF0, 0x29, 0xD1, 0x25, 0x12, 0x06}

	m := chip8.New()
	if err := m.LoadROM(rom); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	// Hold key 3 from cycle 10 on, run 1000 cycles in total.
	m.RunSchedule(1000, []chip8.KeyEvent{{Cycle: 10, Mask: 1 << 3}})

	fmt.Printf("PC=%04x lit pixels=%d\n", m.PC, m.Display.Lit())
	os.Stdout.Write(m.Report())
}
```

Programs can also be parsed from the textual format with `chip8.ParseInput`
and executed with `(*Program).Run`. `Machine.Run(n)` and `Machine.Step()` run
with a fixed key state set via `SetKeys`.

## Design notes

The interpreter decodes straight from memory every cycle (no pre-decoding, so
self-modifying code works) with one `switch` on the top opcode nibble. Hot
scalars (`PC`, `I`, `SP`, timers, keys, RNG state) are locals of the loop, and
the display is 32 `uint64` rows so a sprite row is one rotate, one AND and one
XOR.
