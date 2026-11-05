# chip8 performance benchmark

The spec caps every run at 5,000,000 cycles and one program per input, so each input uses the full budget; compiled implementations finish in roughly 0.05-0.14 s, below the usual 0.3 s target. Inputs come from `gen_bench.py` (fixed seeds, using the assembler and soup generator in `../gen_tests.py`). Expected outputs come from `reference/main.py`, and the cpp, rust, go, d and python implementations all match them.

- `001_cpu_kernel_5m`: an integer "compute kernel" ROM that fills a 256-byte buffer with FX55 block stores, checksums it with FX65 block loads, dispatches through a BNNN jump table, runs a repeated-subtraction division in a nested call and shows the checksum as BCD digits. It tests raw interpreter dispatch: ALU and flag handling, skips, CALL/RET, memory transfers and I arithmetic, with very little drawing. This is the typical mix of a non-graphical CHIP-8 program.
- `002_sprite_scene_5m`: a game-style frame loop that clears the screen, then moves 24 objects (positions kept in memory and read and written with FX65/FX55) and draws each one twice as 8x15 sprites (body plus an offset shadow, so collisions and VF updates happen often). It sets DT once per frame. DXYN at the maximum height of 15 rows makes up a large share of the work, so this tests the display/XOR path the way a real game does.
- `003_mixed_soup_keys_5m`: a full 3584-byte ROM of seeded random instructions (the same generator the public soup tests use, seed 2024), plus a dense schedule of 20,000 key events. It covers every opcode class over a large code footprint: key polling and FX0A waits, timers, RNG, frequent draws and wrap-around. The seed is accepted only if it never faults the stack and keeps changing visible state through the end of the run. This is the mixed, branchy workload.

## Long tier

`python3 bench/gen_bench.py --long [name...]` writes `bench-long/` with the same three programs run for many more
cycles: 001 3,200,000,000 cycles (640x), 002 2,000,000,000 (400x), 003 2,400,000,000 (480x). The soup in 003 uses the
same generator and seed (2024), the same 3584-byte ROM shape and a schedule of 200,000 key events (as before, the
events cover roughly the first half of the run), and is accepted by the same rule as `gen_tests.make_soup` (no stack
fault; visible state still changes in the last quarter), checked at the long cycle count. SPEC.md's cycle limit is raised
from 5,000,000 to 4,000,000,000 (fits an unsigned 32-bit counter). Expected outputs come from `reference/main.py`; at
~1-2 M cycles/s generation takes several hours on a loaded machine (003 runs the reference twice for the acceptance
check).

Times (user CPU, best of 2), measured when the machine was less loaded (load average ~8-15 on 8 cores):

| input | fastest (user s) | others (user s) | peak RSS compiled | python (wall / user, RSS) | size |
| --- | --- | --- | --- | --- | --- |
| 001_cpu_kernel_5m | cpp 8.1 | d 8.2, rust 10.2, go 12.9 | 3 MB | 2541 s / 1605 s, 17 MB | 2.7 KB |
| 002_sprite_scene_5m | d 6.2 | cpp 6.6, rust 7.6, go 9.2 | 3 MB | 1412 s / 1256 s, 17 MB | 2.6 KB |
| 003_mixed_soup_keys_5m | cpp 7.5 | d 8.0, rust 9.3, go 11.1 | 26 MB | 1961 s / 1610 s, 52 MB | 3.0 MB |

`bench-long/` is 2.9 MB. All five implementations pass all three. The Python implementation takes 21-27 minutes of CPU
per input (0.5-0.7 µs per cycle), well over 10 minutes.
