# toml

A TOML 1.0.0 parser and serializer in C++17, with no dependencies beyond the
standard library (GoogleTest is needed only for the tests).

* **Library** (`toml::toml`): parses TOML into a `toml::Value` tree, converts the
  tree to and from the toml-test "tagged JSON" format, and writes a canonical
  TOML document from a tree.
* **CLI** (`toml-tool`): a thin wrapper that decodes TOML to tagged JSON or
  encodes tagged JSON back to canonical TOML.

The parser is a single-pass recursive-descent parser. It is strict: invalid
UTF-8, a byte-order mark, a lone CR, control characters, redefined tables and
keys, out-of-range integers and impossible dates are all rejected. Scalars are
kept as their canonical text (floats as 17 significant digits, date-times with
an uppercase `T`, `Z` for zero offsets, trailing fractional zeros removed), so
nothing is lost between decode and encode. Both directions run in linear time
apart from sorting each table's keys.

## Layout

```
include/toml/   public headers (toml.hpp includes everything)
  value.hpp       Value tree, Type, Origin
  parser.hpp      parse(), ParseError
  datetime.hpp    scan_datetime(): date/time literals, validated as text
  number.hpp      canonical_integer(), canonical_float(), format_float()
  utf8.hpp        is_valid_utf8(), append_utf8()
  tagged_json.hpp to_tagged_json(), from_tagged_json()
  writer.hpp      to_toml(), format_key(), quote_basic_string()
src/            implementation, one file per header
cli/main.cpp    the command-line tool
tests/          GoogleTest unit tests
build.sh        configure + build (Release) into build/
run.sh          run the CLI from any directory
```

## Build

Requires a C++17 compiler, CMake >= 3.20 and (for tests) GoogleTest.

```
./build.sh                         # Release build into ./build
./build/toml_tests                 # run the unit tests (or: ctest --test-dir build)
```

Options: `-DTOML_BUILD_TESTS=OFF` skips the tests and the GoogleTest
requirement. `cmake --install build` installs the library, headers and CLI.

To use the library from another CMake project:

```cmake
add_subdirectory(toml)
target_link_libraries(my_app PRIVATE toml::toml)
```

## Command-line tool

`toml-tool` (or `./run.sh`) reads all of stdin. The first line is the mode,
`decode` or `encode`; the rest is the document.

```
$ printf 'decode\nname = "Tom"\nports = [8001, 0x1F42]\n' | ./run.sh
{"name":{"type":"string","value":"Tom"},"ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]}

$ printf 'decode\nname = \n' | ./run.sh
error

$ printf 'encode\n{"a":{"type":"integer","value":"1"},"t":{"b":{"type":"bool","value":"true"}}}\n' | ./run.sh
a = 1

[t]
b = true
```

* `decode` prints one line of compact, key-sorted tagged JSON, or `error` if
  the document is not valid TOML 1.0.0. The exit code is 0 either way.
* `encode` prints the canonical TOML: plain pairs first, then sub-tables and
  arrays of tables as headers, all in ascending key order. `decode(encode(x))`
  equals `x`.
* An unknown mode, or malformed JSON in encode mode, exits non-zero with a
  message on stderr.

## Library example

```cpp
#include <iostream>
#include "toml/toml.hpp"

int main() {
  try {
    toml::Value doc = toml::parse(R"(
      title = "Example"
      [server]
      host = "localhost"
      ports = [8001, 8002]
      started = 1979-05-27T07:32:00Z
    )");

    std::cout << doc.find("title")->as_string() << "\n";            // Example
    const toml::Value& server = *doc.find("server");
    for (const toml::Value& p : server.find("ports")->items())
      std::cout << p.as_integer() << " ";                           // 8001 8002
    std::cout << server.find("started")->text() << "\n";            // 1979-05-27T07:32:00Z

    std::cout << toml::to_tagged_json(doc) << "\n";   // tagged JSON
    std::cout << toml::to_toml(doc);                   // canonical TOML
  } catch (const toml::ParseError& e) {
    std::cerr << "invalid TOML: " << e.what() << "\n";  // includes line and column
    return 1;
  }
}
```

### API summary

| Function | Purpose |
|----------|---------|
| `Value parse(std::string_view)` | TOML text to tree; throws `ParseError` (with `line()`, `column()`) |
| `std::string to_tagged_json(const Value&)` | compact, key-sorted tagged JSON |
| `Value from_tagged_json(std::string_view)` | tagged JSON to tree; throws `JsonError` |
| `std::string to_toml(const Value&)` | canonical TOML for a table |

`Value` is a scalar (`type()`, `text()`, `as_string()`, `as_integer()`,
`as_float()`, `as_bool()`), an array (`items()`) or a table (`members()`,
`find(key)`); `kind()` says which. Tables are ordered `std::map`s, so iteration
is in code point order. Accessors of the wrong kind throw `toml::TypeError`.
`Value::origin()` reports how a table came into being (header, dotted key,
inline table, ...), which is what the parser uses to enforce TOML's
redefinition rules.

## Tests

`tests/` holds GoogleTest suites per module (UTF-8, numbers, date-times, the
parser's valid and invalid documents, tagged JSON, the writer, and
round-trips). The repository-level conformance suite runs the CLI against the
toml-test corpus: `python3 run_tests.py toml -- toml/run.sh`.
