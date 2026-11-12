# inflate

A from-scratch DEFLATE (RFC 1951) decoder in C++17: a small, dependency-free
library plus a thin command-line tool. It uses a table-driven canonical Huffman
decoder (a 10-bit root table for literal/length codes, 8-bit for distances,
second-level tables for longer codes) and is strict: every malformation
described in the problem's `SPEC.md` is reported, including trailing bytes after
the final block.

No zlib or other decompression library is used; only the C++ standard library.
GoogleTest is needed to build the tests.

## Layout

| Path | Contents |
|------|----------|
| `include/inflate/inflate.hpp` | Public API: `inflate()`, `Options`, `Result` |
| `include/inflate/error.hpp` | `Error` codes and `to_string()` |
| `include/inflate/bit_reader.hpp` | LSB-first bit reader (peek past the end, never consume past it) |
| `include/inflate/huffman.hpp`, `src/huffman.cpp` | Two-level canonical Huffman table build and decode |
| `include/inflate/tables.hpp` | RFC 1951 length/distance/code-length constants |
| `include/inflate/hex.hpp`, `src/hex.cpp` | Hex encode/decode helpers |
| `src/inflate.cpp` | Block parsing (stored / fixed / dynamic) and LZ77 copy |
| `cli/main.cpp` | The command-line tool |
| `tests/` | GoogleTest unit and CLI tests |

## Build

Requires CMake >= 3.20 and a C++17 compiler.

```sh
./build.sh                     # Release build into ./build
# or, manually:
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build         # run the tests (needs GoogleTest)
```

CMake options: `INFLATE_BUILD_CLI` (default ON), `INFLATE_BUILD_TESTS`
(default ON; set OFF if GoogleTest is not installed).

## Command-line tool

```sh
echo 4b4c4a862000 | ./run.sh      # -> 616263616263616263
```

Standard input is one line of lowercase hex: a raw DEFLATE stream (no zlib or
gzip wrapper). Standard output is one line: the decompressed bytes as hex, or the
word `error` if the stream is malformed. The exit status is 0 in both cases.

## Library

```cpp
#include <iostream>
#include <vector>
#include "inflate/inflate.hpp"
#include "inflate/hex.hpp"

int main() {
  std::vector<std::uint8_t> stream;
  inflate::hex_decode("4b4c4a862000", stream);

  inflate::Options opts;
  opts.max_output = 16u << 20;  // optional guard against decompression bombs

  inflate::Result r = inflate::inflate(stream, opts);
  if (!r) {
    std::cerr << "bad stream: " << inflate::to_string(r.error) << '\n';
    return 1;
  }
  std::cout << inflate::hex_encode(r.data) << '\n';  // 616263616263616263
}
```

Link against the `inflate::inflate` target (e.g. via `add_subdirectory`):

```cmake
add_subdirectory(inflate)
target_link_libraries(my_app PRIVATE inflate::inflate)
```

`inflate::inflate(data, size, out, options)` writes into a caller-supplied
vector instead and returns an `inflate::Error`.

## Complexity

Decoding is O(I + O) for I input and O output bytes plus O(n_sym + 2^R) table
construction per block (R = root table width); each back-reference costs
O(length).
