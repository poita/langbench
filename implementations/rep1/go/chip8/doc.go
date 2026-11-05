// Package chip8 is a small, deterministic CHIP-8 interpreter.
//
// The machine follows a fully specified variant of the classic semantics:
// shifts operate on VX in place, FX55/FX65 leave I unchanged, BNNN always
// uses V0, sprites wrap around both screen edges, timers tick once every
// eight cycles and the random number generator is a fixed 32-bit LCG. Given
// the same ROM, cycle budget and key schedule, a run always produces the same
// final state.
//
// The package is organised by responsibility:
//
//   - machine.go: the Machine type (memory, registers, timers) and its setup
//   - run.go:     the fetch-decode-execute loop
//   - display.go: the 64x32 display stored as 32 row words
//   - input.go:   parsing the textual ROM / cycles / key-schedule input
//   - output.go:  rendering the final display and CPU state as text
//
// Typical use:
//
//	m := chip8.New()
//	if err := m.LoadROM(rom); err != nil { ... }
//	m.RunSchedule(1000, []chip8.KeyEvent{{Cycle: 10, Mask: 1 << 5}})
//	os.Stdout.Write(m.Report())
package chip8
