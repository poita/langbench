# chip8

A deterministic CHIP-8 interpreter written in Go, as a reusable library plus a
small command-line tool. It uses only the standard library.

The semantics are a fully specified variant of CHIP-8: shifts work on `VX` in
place, `FX55`/`FX65` leave `I` unchanged, `BNNN` always uses `V0`, sprites wrap
around the screen edges, the timers tick once every 8 cycles, and `CXNN` uses
a fixed-seed 32-bit LCG. Every cycle the opcode is fetched from memory and
decoded afresh, so self-modifying programs work.

## Layout

| File | Responsibility |
|------|----------------|
| `machine.go` | `Machine` state, `New`, `LoadROM`, `Run`, `Step` (fetch + timers) |
| `exec.go` | Instruction decode and execution |
| `display.go` | 64x32 `Display`, XOR sprite drawing with wrap-around |
| `rng.go` | The specified LCG |
| `keys.go` | `KeyEvent` / `KeySchedule` |
| `input.go` | `ParseInput`: the textual ROM/cycles/key-schedule format |
| `output.go` | `Machine.Report`: the 34-line textual state report |
| `cmd/chip8` | The command-line tool |

## Build

```
./build.sh          # or: go build -o bin/chip8 ./cmd/chip8
```

Requires Go 1.27 or newer. Run the tests with `go test ./...`.

## Command-line use

`chip8` reads its input from stdin and writes the result to stdout
(`./run.sh` is a wrapper that finds the binary from any directory).

Input is three lines (the third is optional):

```
<rom-hex>         lowercase hex, 1..3584 bytes, loaded at 0x200
<cycles>          decimal, 0..4000000000
<key-schedule>    events "<cycle>:<mask>" separated by spaces; mask is 4 hex digits
```

Output is 34 lines: the 32 display rows (`#` lit, `.` unlit), then
`PC=… I=… SP=… DT=… ST=…`, then `V=` followed by the sixteen registers.

```
$ printf '60ff7001610180141208\n6\n' | ./run.sh | tail -2
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

The exit status is 0 on success and 1 on malformed input.

## Library use

```go
package main

import (
	"fmt"

	"github.com/peter/chip8"
)

func main() {
	m := chip8.New()

	// V0 = 5; I = glyph for V0; draw it at (V1, V2) = (0, 0); loop forever.
	rom := []byte{0x60, 0x05, 0xF0, 0x29, 0xD1, 0x25, 0x12, 0x06}
	if err := m.LoadROM(rom); err != nil {
		panic(err)
	}

	// Run 100 cycles; key 3 is pressed from cycle 50 on.
	m.Run(100, chip8.KeySchedule{{Cycle: 50, Mask: 1 << 3}})

	fmt.Print(m.Display.String())
	fmt.Printf("PC=%04x I=%04x\n", m.PC, m.I)
}
```

Use `Machine.Step` to advance one cycle at a time (setting `Machine.Keys`
yourself), or `ParseInput` / `Program.Execute` / `Machine.Report` to work with
the textual format used by the CLI.

Pushing onto a full stack or popping an empty one is unspecified by the
format; this implementation ignores such operations rather than panicking.
