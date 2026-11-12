# qrcode

A small, dependency-free C++20 library that encodes text as QR Code Model 2
symbols (ISO/IEC 18004, versions 1-40, error correction levels L/M/Q/H), plus a
command-line tool that prints the module matrix as text.

Features: numeric / alphanumeric / byte mode selection, smallest-version
selection, Reed-Solomon error correction, fixed or automatic (penalty-scored)
mask selection. A single segment is used and no ECI header is emitted.

## Layout

| Path | Contents |
|------|----------|
| `include/qrcode/qrcode.hpp` | Public API: `encode()`, `Symbol`, `Ecl`. |
| `include/qrcode/tables.hpp` | Capacities, block structure, alignment positions. |
| `include/qrcode/segment.hpp` | Mode/version selection, data bit stream, padding. |
| `include/qrcode/bit_buffer.hpp` | MSB-first bit buffer. |
| `include/qrcode/reed_solomon.hpp`, `codewords.hpp` | GF(2^8) arithmetic, ECC, block interleaving. |
| `include/qrcode/matrix.hpp` | Module grid: function patterns, format/version info, data placement, masks. |
| `include/qrcode/penalty.hpp` | Mask penalty rules N1-N4. |
| `cli/main.cpp` | The command-line tool. |
| `tests/` | GoogleTest unit tests. |

## Build

Requires a C++20 compiler, CMake >= 3.20 and (for the tests) GoogleTest.

```sh
./build.sh          # Release build of library, CLI and tests; runs ctest
```

or manually:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build
```

Options: `-DQRCODE_BUILD_TESTS=OFF` (no GoogleTest needed), `-DQRCODE_BUILD_CLI=OFF`.
Set `QRCODE_SKIP_TESTS=1` to make `build.sh` skip running ctest.

## Command-line usage

`run.sh` (or `build/qrcode-cli`) reads queries from standard input, one per
line, in the form

    <ecl> <mask> <text>

where `<ecl>` is `L`, `M`, `Q` or `H`, `<mask>` is `0`..`7` or `auto`, and
`<text>` is the rest of the line (interior spaces and UTF-8 allowed). For each
query it prints

    version <v> mask <m>
    <size rows of '#' (dark) and '.' (light)>
    <empty line>

```sh
$ echo 'L auto 01234567' | ./run.sh
version 1 mask 3
#######.##..#.#######
...
```

Malformed lines or text that does not fit in version 40 print a message to
stderr and exit with status 1.

## Library example

```cpp
#include <iostream>
#include "qrcode/qrcode.hpp"

int main() {
    qrcode::Symbol s = qrcode::encode("HELLO WORLD", qrcode::Ecl::M);  // auto mask
    std::cout << "version " << s.version() << " mask " << s.mask() << "\n";
    for (int y = 0; y < s.size(); ++y) {
        for (int x = 0; x < s.size(); ++x) std::cout << (s.dark(x, y) ? "##" : "  ");
        std::cout << "\n";
    }
}
```

Link against the `qrcode::qrcode` CMake target (`add_subdirectory(qrcode)`).
`encode(text, ecl, mask)` accepts `0..7` or `qrcode::kAutoMask`; it throws
`std::invalid_argument` for a bad mask and `std::length_error` if the text does
not fit.

## Tests

`ctest --test-dir build` runs the GoogleTest suite (tables, bit buffer,
segments, Reed-Solomon, matrix drawing, penalties and full-symbol examples).
