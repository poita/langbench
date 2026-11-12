# softfloat

IEEE-754 binary32 (single precision) addition, subtraction, multiplication,
division and square root implemented purely with integer arithmetic. Values are
exchanged as raw 32-bit patterns; results are round-to-nearest-even with full
gradual underflow (denormals), signed zeros, infinities, and canonical NaN
(`0x7fc00000`) output. Exception flags are not modelled.

No host floating point is used by the library. Every intermediate fits in 64 bits:

- **add/sub** – align with 38 guard bits, fold shifted-out bits into a sticky bit.
- **mul** – exact 48-bit product.
- **div** – one 64-bit integer divide; sticky = non-zero remainder.
- **sqrt** – restoring digit-by-digit square root (≈31 steps); sticky = non-zero remainder.
- All four feed one shared `round_pack` step that rounds once, directly onto the
  normal or denormal grid.

## Layout

| Path | Purpose |
|---|---|
| `include/softfloat/softfloat.h` | public API: `add sub mul div sqrt` |
| `include/softfloat/bits.h` | bit-pattern helpers and constants |
| `include/softfloat/line.h` | text front end (`evaluate_line`, `evaluate_all`) |
| `src/` | implementation (one file per operation + `round_pack`) |
| `cli/main.cpp` | the command-line tool |
| `tests/` | GoogleTest unit tests (including a randomised check against the host FPU used purely as a test oracle) |
| `examples/basic.cpp` | library usage example |

## Build

Requires a C++20 compiler and CMake ≥ 3.20 (GoogleTest optional, for tests).

    ./build.sh                    # Release build into ./build
    ./build/softfloat_tests       # run unit tests (or: ctest --test-dir build)

or by hand: `cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build`.
Options: `SOFTFLOAT_BUILD_CLI`, `SOFTFLOAT_BUILD_EXAMPLES`, `SOFTFLOAT_BUILD_TESTS`.

## Command line

`run.sh` (or `build/softfloat_cli`) reads operations on stdin, one per line, and
writes one 8-digit lowercase hex result per line:

    $ printf 'add 3f800000 3f800000\ndiv 3f800000 40400000\nsqrt 40000000\n' | ./run.sh
    40000000
    3eaaaaab
    3fb504f3

Operations are `add|sub|mul|div <a> <b>` and `sqrt <a>`, operands being 8
lowercase hex digits. Malformed input prints a message to stderr and exits 1.

## Library example

```cpp
#include <cstdio>
#include "softfloat/softfloat.h"

int main() {
  namespace sf = softfloat;
  sf::Bits32 third = sf::div(0x3f800000, 0x40400000);   // 1/3
  std::printf("%08x\n", third);                          // 3eaaaaab
}
```

Link with the `softfloat::softfloat` CMake target. Note the functions are named
`add`, `div`, `sqrt`, … inside namespace `softfloat`; qualify them (as above) to
avoid clashing with `::div` / `::sqrt` from the C library.
