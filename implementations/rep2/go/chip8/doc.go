// Package chip8 implements a deterministic CHIP-8 interpreter.
//
// The package is split by responsibility:
//
//   - Machine (machine.go, exec.go): the CPU, memory, timers and the
//     fetch-decode-execute cycle.
//   - Display (display.go): the 64x32 monochrome frame buffer.
//   - RNG (rng.go): the specified 32-bit linear congruential generator.
//   - KeySchedule (keys.go): time-stamped keypad states.
//   - ParseInput and Output (input.go, output.go): the textual
//     program format and the textual report of the final machine state.
//
// The semantics are fixed and fully deterministic: shifts operate on VX in
// place, FX55/FX65 leave I unchanged, BNNN always uses V0, sprites wrap, the
// timers tick once every eight cycles, and CXNN draws from a fixed-seed LCG.
//
// Every cycle the opcode is fetched from memory and decoded afresh, so
// self-modifying programs behave as expected.
package chip8
