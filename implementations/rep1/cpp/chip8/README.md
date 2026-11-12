# chip8

A small, dependency-free C++17 library and command-line tool implementing a
fully deterministic CHIP-8 interpreter. Given a ROM, a cycle budget and an
optional key schedule, it runs exactly that many cycles and reports the 64x32
display, the CPU registers and the timers.

Behaviour follows the project's specification (`problems/chip8/SPEC.md`):
in-place shifts, `FX55`/`FX65` leave `I` unchanged, 12-bit address masking,
wrap-around sprites, timers ticking every 8 cycles, and a fixed LCG for `CXNN`.
Every instruction is fetched and decoded from memory on every cycle, so
self-modifying programs work.

## Layout

| Path | Contents |
|------|----------|
| `include/chip8/` | public headers (`chip8.hpp` is the umbrella) |
| `src/` | library implementation |
| `tools/main.cpp` | the `chip8` command-line tool |
| `tests/` | GoogleTest unit tests |

Library modules: `rng` (the `CXNN` generator), `font`, `display` (XOR frame
buffer), `keypad` (key state and `KeySchedule`), `machine` (CPU, memory and the
cycle loop), `job` (parsing the text format, `run_job`), `report` (output
formatting).

## Build

Requires a C++17 compiler and CMake >= 3.20; the tests need GoogleTest.

```sh
./build.sh                 # Release build into ./build
ctest --test-dir build     # or ./build/chip8_tests
```

Or by hand: `cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build`.
Options: `-DCHIP8_BUILD_TESTS=OFF`, `-DCHIP8_BUILD_CLI=OFF`.

## Command-line use

`./run.sh` (or `build/chip8`) reads the job on stdin and writes the result to
stdout. It exits 0 on success and 1 (message on stderr) on malformed input.

Input:

```
<rom-hex>             ROM bytes, lowercase hex (1..3584 bytes), loaded at 0x200
<cycles>              number of cycles to run (0..4000000000)
<key-schedule>        optional: "<cycle>:<mask4hex>" events separated by spaces
```

Output: 32 display rows of `#`/`.`, then `PC=.. I=.. SP=.. DT=.. ST=..`, then
`V=` and the 16 registers.

```sh
printf '60ff7001610180141208\n6\n' | ./run.sh | tail -2
# PC=0208 I=0000 SP=0 DT=00 ST=00
# V=01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

## Library example

```cpp
#include <iostream>
#include "chip8/chip8.hpp"

int main() {
  // V0 = 0xFF; V0 += 1; V1 = 1; V0 += V1; jump to self.
  const std::vector<std::uint8_t> rom = {0x60, 0xFF, 0x70, 0x01, 0x61, 0x01,
                                         0x80, 0x14, 0x12, 0x08};
  chip8::Machine m;
  m.load_rom(rom);

  chip8::KeySchedule keys = chip8::parse_key_schedule("3:0001 5:0000");
  m.run(6, keys);                       // exactly 6 cycles

  std::cout << chip8::format_status(m) << "\n"      // PC=0208 I=0000 ...
            << chip8::format_registers(m) << "\n";  // V=01 01 00 ...
  std::cout << m.display().to_text();               // 32 lines of 64 chars
}
```

Link against the `chip8::chip8` CMake target (`add_subdirectory` this project
and `target_link_libraries(app PRIVATE chip8::chip8)`).

The text format can also be used directly:
`chip8::Machine m = chip8::run_job(chip8::parse_job(text));`
(`parse_job` throws `chip8::ParseError` on malformed input).

## Notes

- Stack overflow/underflow is unspecified by the specification; this
  implementation stays memory-safe and treats a call on a full stack and a
  return on an empty stack as no-ops.
- The key schedule is consumed with a cursor, so the per-cycle overhead is O(1).
