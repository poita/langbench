# protowire

A small C++20 library and command-line tool implementing a Protocol Buffers
(proto3) wire-format codec driven by a schema. It decodes hex-encoded wire
bytes into a canonical text form and encodes that text form back into
canonical wire bytes. It uses only the C++ standard library (GoogleTest is
needed only for the tests); no protobuf code is involved.

## Layout

| Path | Purpose |
|---|---|
| `include/protowire/schema.hpp`, `src/schema.cpp` | schema parser, message/field descriptors |
| `include/protowire/wire.hpp` | varints, zigzag, bounds-checked `Reader` |
| `include/protowire/scalar.hpp` | wire value <-> stored value conversion per field type |
| `include/protowire/value.hpp` | value tree (`Message`, `FieldValue`) |
| `include/protowire/decoder.hpp` | bytes -> value tree (merging, packed, unknown/group skipping) |
| `include/protowire/encoder.hpp` | value tree -> canonical bytes (size pass + write pass) |
| `include/protowire/text_format.hpp` | canonical text formatter and relaxed text parser |
| `include/protowire/hex.hpp`, `utf8.hpp` | hex and strict UTF-8 helpers |
| `include/protowire/codec.hpp` | one-call helpers: `decodeToText`, `encodeFromText` |
| `include/protowire/batch.hpp` | the stdin request-file contract used by the CLI |
| `cli/main.cpp` | thin CLI over `processInput` |
| `tests/` | GoogleTest unit tests |

Errors are reported as exceptions derived from `protowire::Error`
(`SchemaError`, `WireError`, `TextError`, `HexError`).

Decoding is linear in the payload; encoding computes every node's size once
and then writes, so it is linear in the output regardless of nesting depth.

## Build

Requires a C++20 compiler, CMake >= 3.20 and (for tests) GoogleTest.

```sh
./build.sh                 # Release build into ./build
./build/protowire_tests    # run unit tests (or: ctest --test-dir build)
```

Configure without tests: `cmake -S . -B build -DPROTOWIRE_BUILD_TESTS=OFF`.

## CLI

`./run.sh` (or `build/protowire`) reads all of stdin and writes one output
line per request to stdout; the exit code is always 0 and a malformed request
prints `error`.

```
message Inner { sint32 v = 1; }
message Outer { int32 a = 1; string b = 2; repeated int32 c = 3; Inner d = 4; }
--
encode Outer {a: 1, b: "x", c: [1, 2], d: {v: -5}}
decode Outer 08011201781a02010222020809
decode Outer 08ff
```

prints

```
08011201781a02010222020809
{a: 1, b: "x", c: [1, 2], d: {v: -5}}
error
```

The schema is everything before the first line that is exactly `--`; each
later line is `decode <Name> <lowercase hex>` or `encode <Name> <text>`. The
exact grammar, wire rules and canonical text form are in the problem's
`SPEC.md`.

## Library example

```cpp
#include <iostream>
#include "protowire/codec.hpp"

int main() {
  auto schema = protowire::Schema::parse(R"(
    message Inner { sint32 v = 1; }
    message Outer { int32 a = 1; string b = 2; repeated int32 c = 3; Inner d = 4; }
  )");
  const auto& outer = *schema.findMessage("Outer");

  auto bytes = protowire::encodeFromText(outer, R"({a: 1, c: [1, 2], d: {v: -5}})");
  std::cout << protowire::toHex(bytes) << "\n";                      // 08011a02010222020809
  std::cout << protowire::decodeToText(outer, bytes) << "\n";        // {a: 1, c: [1, 2], d: {v: -5}}

  try {
    protowire::decodeToText(outer, protowire::fromHex("08ff"));
  } catch (const protowire::WireError& e) {
    std::cout << "error: " << e.what() << "\n";
  }
}
```

Link against the `protowire::protowire` CMake target (e.g. via
`add_subdirectory`).
