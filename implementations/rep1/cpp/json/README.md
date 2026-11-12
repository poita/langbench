# jsoncanon

A strict JSON (RFC 8259) parser and canonical serializer in C++20, with no
dependencies beyond the standard library. It is written from scratch: no
existing JSON library is used.

Given one JSON document it either reports that the document is invalid or
produces its **canonical form**:

- no whitespace outside strings;
- object members sorted by key in UTF-16 code-unit order, duplicate keys
  collapsed to the value of the last occurrence;
- strings escape only `"`, `\` and U+0000–U+001F (`\b \f \n \r \t`, otherwise
  lowercase `\u00xx`); everything else is emitted as raw UTF-8;
- numbers are echoed textually (never converted to floating point), so
  integers of any size survive; only the exponent is normalised
  (`1E+05` → `1e5`, `1e-0` → `1e0`).

Strictness: input must be valid UTF-8 without a BOM; whitespace is only space,
tab, LF, CR; lone/mismatched `\u` surrogates, leading zeros, trailing commas,
etc. are rejected; nesting deeper than 512 is rejected (the whole document is
validated even where a duplicate key would later discard a value).

## Layout

| Path | Purpose |
|------|---------|
| `include/jsoncanon/utf8.hpp`, `src/utf8.cpp` | strict UTF-8 validation, encoding, UTF-16-order key comparison |
| `include/jsoncanon/value.hpp`, `src/value.cpp` | the document tree (`Value`, `Member`, `Number`) |
| `include/jsoncanon/parser.hpp`, `src/parser.cpp` | recursive-descent parser (`parse`, `try_parse`, `ParseError`) |
| `include/jsoncanon/serializer.hpp`, `src/serializer.cpp` | canonical serializer, writes directly into one output buffer |
| `include/jsoncanon/jsoncanon.hpp`, `src/canonicalize.cpp` | umbrella header and `canonicalize()` |
| `cli/main.cpp` | the command-line tool |
| `tests/` | GoogleTest unit tests |

## Build

Requires a C++20 compiler and CMake ≥ 3.20 (GoogleTest is needed only for the tests).

```sh
./build.sh                 # Release build into ./build
# or manually:
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build     # run the unit tests
```

CMake options: `JSONCANON_BUILD_TESTS` (default ON when top-level; skipped with
a warning if GoogleTest is missing), `JSONCANON_BUILD_CLI` (default ON).
The library is also usable via `add_subdirectory` as target `jsoncanon::jsoncanon`.

## Command line

`jsoncanon` reads the whole of stdin as one document and writes one line to stdout:
the canonical form, or `invalid`. The exit status is 0 in both cases; stderr is unused.

```sh
$ echo '{ "b": [1, 2.50, 1E+3], "a": "héllo\/", "b": null }' | ./run.sh
{"a":"héllo/","b":null}
$ echo '[1, 2, ]' | ./run.sh
invalid
```

## Library

```cpp
#include <iostream>
#include "jsoncanon/jsoncanon.hpp"

int main() {
  // One call: canonical text or std::nullopt.
  if (auto out = jsoncanon::canonicalize(R"({"b":1E2,"a":[true, null]})"))
    std::cout << *out << '\n';              // {"a":[true,null],"b":1e2}

  // Or work with the tree.
  try {
    jsoncanon::Value doc = jsoncanon::parse(R"({"name":"x","n":[1,2]})");
    for (const auto& m : doc.as_object())   // members in input order, duplicates kept
      std::cout << m.key << '\n';
    std::cout << jsoncanon::serialize(doc) << '\n';
  } catch (const jsoncanon::ParseError& e) {
    std::cerr << e.what() << " (offset " << e.offset() << ")\n";
  }
}
```

API summary (namespace `jsoncanon`):

- `Value parse(std::string_view, const ParseOptions& = {})` – throws `ParseError`;
  `std::optional<Value> try_parse(...)` – does not throw.
- `ParseOptions::max_depth` – default 512.
- `std::string serialize(const Value&)` / `void serialize(const Value&, std::string&)`.
- `std::optional<std::string> canonicalize(std::string_view, ...)`.
- `utf8::is_valid`, `utf8::append_code_point`, `utf8::compare_utf16`.

## Design notes

Validation (UTF-8), parsing and serialization are separate linear passes. Strings
are stored decoded; numbers as canonical text. The serializer stable-sorts each
object's member pointers by UTF-16 order and writes the last of each equal run,
emitting everything into a single buffer (no per-subtree strings, so no
O(n·depth) copying). Key comparison works directly on UTF-8: bytes are compared
up to the first difference, and only that code point is decoded and ranked
(U+E000–U+FFFF rank after all supplementary characters).
