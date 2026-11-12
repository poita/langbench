# chip8

A small, deterministic CHIP-8 interpreter in C++17: a reusable library plus a
thin command-line tool. The instruction semantics (shifts, `FX55`/`FX65`,
`BNNN`, sprite wrapping, timer rate, RNG) follow the specification in
`problems/chip8/SPEC.md` exactly, so a run is fully reproducible.

The interpreter fetches and decodes from memory on every cycle (no
pre-decoding or caching), consumes the key schedule in order, and uses the
specified LCG rather than a library RNG. It depends only on the C++ standard
library; GoogleTest is used for the tests.

## Layout

| Path | Responsibility |
|------|----------------|
| `include/chip8/rng.hpp` | The `CXNN` linear congruential generator |
| `include/chip8/font.hpp` | Built-in font data and addresses |
| `include/chip8/display.hpp`, `src/display.cpp` | 64x32 XOR frame buffer, text rendering |
| `include/chip8/machine.hpp`, `src/machine.cpp` | CPU state and the fetch/execute/timer cycle |
| `include/chip8/key_schedule.hpp`, `src/key_schedule.cpp` | Key-event type and parser |
| `include/chip8/program.hpp`, `src/program.cpp` | Parsing the stdin format; formatting the report |
| `include/chip8/runner.hpp`, `src/runner.cpp` | Running a machine for N cycles with a key schedule |
| `include/chip8/chip8.hpp` | Umbrella header |
| `cli/main.cpp` | The command-line tool |
| `tests/` | GoogleTest unit tests |

## Build

Requires CMake >= 3.20, a C++17 compiler and (for tests) GoogleTest.

```sh
./build.sh            # Release build into ./build
ctest --test-dir build   # or ./build/tests/chip8_tests
```

CMake options: `-DCHIP8_BUILD_TESTS=OFF`, `-DCHIP8_BUILD_CLI=OFF`. The library
is exported as the target `chip8::chip8`.

## Command-line usage

`./run.sh` (or `build/chip8`) reads all input from stdin and writes to stdout:

```
<rom-hex>             ROM bytes, lowercase hex, loaded at 0x200 (1..3584 bytes)
<cycles>              number of cycles to execute (0..4000000000)
<key-schedule>        optional: space-separated "<cycle>:<mask4hex>" events
```

Output is 34 lines: the 32 display rows (`#`/`.`), then
`PC=.... I=.... SP=n DT=.. ST=..`, then `V=` and the 16 registers.

```sh
$ printf '60ff7001610180141208\n6\n' | ./run.sh | tail -2
PC=0208 I=0000 SP=0 DT=00 ST=00
V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

Malformed input prints a message to stderr and exits with status 1.

## Library example

```cpp
#include <iostream>
#include "chip8/chip8.hpp"

int main() {
    // V0 = 5; I = glyph for V0; draw it at (V1, V2); loop forever.
    chip8::Program p = chip8::parse_program("6005f029d1251208\n100\n");

    chip8::Machine m = chip8::run_program(p);   // load ROM + run all cycles
    std::cout << chip8::format_state(m);

    // Or drive it step by step:
    chip8::Machine m2;
    m2.load_rom(p.rom);
    m2.set_keys(1u << 0xA);                      // hold key A
    m2.step();
    std::cout << std::hex << m2.pc() << "\n";    // 202
}
```

Link with `chip8::chip8` (`target_link_libraries(app PRIVATE chip8::chip8)`).

### API summary

- `chip8::Machine`: `load_rom`, `set_keys`, `step`, plus read-only accessors
  (`pc`, `index`, `sp`, `delay_timer`, `sound_timer`, `reg`, `peek`, `display`).
- `chip8::run(machine, cycles, schedule)` / `chip8::run_program(program)`.
- `chip8::parse_program`, `chip8::parse_key_schedule`, `chip8::format_state`.
- `chip8::Display`, `chip8::Rng`, `chip8::kFont`.

Pushing a 17th stack entry or popping an empty stack is unspecified by the
spec; this implementation ignores such an instruction's stack effect.
