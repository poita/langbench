// Package chip8 implements a deterministic CHIP-8 interpreter.
//
// The package is split by responsibility:
//
//   - input.go:   parsing the textual input (ROM hex, cycle budget, key schedule)
//   - machine.go: the machine state and the fetch-decode-execute loop
//   - display.go: the 64x32 display held as 32 row words
//   - font.go:    the built-in hexadecimal font
//   - output.go:  rendering the display and CPU state as text
//
// A typical use is:
//
//	in, _ := chip8.ParseInput(r)
//	m := chip8.New()
//	m.LoadROM(in.ROM)
//	m.Run(in.Cycles, in.Events)
//	os.Stdout.Write(m.Render())
//
// The behaviour (shifts, FX55/FX65, BNNN, sprite wrapping, timer rate and the
// random number generator) follows the project specification exactly and is
// fully deterministic.
package chip8
