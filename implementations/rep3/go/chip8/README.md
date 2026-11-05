# chip8

A small, deterministic CHIP-8 interpreter written in Go (standard library only),
with a reusable library and a thin command-line tool.

Given a ROM, an exact cycle budget and an optional key schedule, it executes
precisely that many instruction cycles and prints the 64x32 display and the CPU
state. Behaviour follows the project specification (shifts operate in place,
`FX55`/`FX65` leave `I` unchanged, `BNNN` uses `V0`, sprites wrap, timers tick
every 8 cycles, and the RNG is a fixed LCG), so runs are fully reproducible.

## Layout

| File | Responsibility |
|------|----------------|
| `machine.go` | machine state and the fetch-decode-execute loop (`Machine.Run`) |
| `display.go` | the display as 32 row words; sprite XOR via 64-bit rotate |
| `input.go`   | parsing the ROM hex, cycle count and key schedule |
| `output.go`  | rendering the 34-line report (`Machine.Render`) |
| `font.go`    | the built-in hex font |
| `cmd/chip8`  | the command-line tool |

## Build

```sh
./build.sh          # produces bin/chip8   (equivalent to: go build -o bin/chip8 ./cmd/chip8)
go test ./...       # run the unit tests
```

Requires Go 1.27 or newer; there are no third-party dependencies.

## Command-line usage

`./run.sh` (or `bin/chip8`) reads stdin and writes stdout:

```
<rom-hex>
<cycles>
<key-schedule>      (optional; events "<cycle>:<mask4hex>" separated by spaces)
```

```sh
$ printf '60ff7001610180141208\n6\n' | ./run.sh | tail -2
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

The output is 32 display rows of `#`/`.`, then a `PC=… I=… SP=… DT=… ST=…` line
and a `V=…` register line. Malformed input prints a message to stderr and exits 1.

## Library example

```go
package main

import (
	"os"

	"github.com/example/chip8"
)

func main() {
	in, err := chip8.ParseInputString("6a3e6b1e6000f029dab5\n5\n")
	if err != nil {
		panic(err)
	}
	m := chip8.New()
	m.LoadROM(in.ROM)
	m.Run(in.Cycles, in.Events) // may be called repeatedly to continue a run
	os.Stdout.Write(m.Render())
}
```

Machine state (`m.V`, `m.PC`, `m.Display`, …) is exported for inspection, and
key presses can be scheduled with `[]chip8.KeyEvent{{Cycle: 9, Mask: 0x0300}}`.

## Design notes

The interpreter decodes straight from memory on every cycle with a single
`switch` on the top nibble; hot scalars (`PC`, `I`, `SP`, timers, key mask, RNG)
are locals inside `Run`. Sprites are XORed a row at a time into 64-bit row words
using a rotate, which gives horizontal wrap-around for free.
