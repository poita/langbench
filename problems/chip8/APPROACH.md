# chip8: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

## Algorithm

A fetch-decode-execute interpreter. Parse the input into the initial machine
state, the cycle count `N` and the key schedule; step the machine exactly `N`
times; then format the display and registers.

Each step applies any key event due at that cycle, fetches the opcode at `PC`,
decodes it, executes it and ticks the timers, all as SPEC.md describes. The
machine state is the fixed-size model of SPEC.md: memory, registers, stack,
timers, key state, RNG state and a 64×32 display.

## Required rules

1. **Interpret every cycle from memory.** Fetch and decode the opcode at `PC`
   on every cycle. No pre-decoding of the program, decoded-instruction caches,
   block translation or JIT: programs write to memory and may run what they
   wrote.
2. **The key schedule is consumed in order**, taking the next event when its
   cycle arrives: O(1) per cycle, with no search.
3. **The RNG is the specified generator**, not a library one.

## Complexity

Each step is O(1), except a sprite draw (O(rows)) and the register block
transfers (O(registers)). The run is O(N + input size), independent of the
program's size.
