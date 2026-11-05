// Package chip8 implements a deterministic CHIP-8 interpreter.
//
// The package is split by responsibility:
//
//   - font.go:    the built-in hexadecimal font and memory layout constants.
//   - display.go: the 64x32 one-bit display stored as 32 row words.
//   - rng.go:     the 32-bit linear congruential generator behind CXNN.
//   - machine.go: the machine state and the fetch-decode-execute loop.
//   - input.go:   parsing of the textual input format (ROM, cycles, key schedule).
//   - output.go:  rendering of the display and CPU state as text.
//
// A typical use:
//
//	m := chip8.New()
//	if err := m.LoadROM(rom); err != nil { ... }
//	m.Run(1000, schedule)
//	os.Stdout.Write(m.Format())
//
// All behaviour (shift semantics, sprite wrapping, timer rate, RNG) is the
// fixed variant described in the project's SPEC.md.
package chip8
