# jqcpp

A small, dependency-free C++20 implementation of a subset of the
[`jq`](https://jqlang.github.io/jq/) filter language (semantics of jq 1.7,
`jq -c`). It ships as

* a **library** (`jqcpp`) with its own JSON parser, JSON serialiser and
  filter interpreter — no JSON or jq library is used; and
* a thin **command-line tool** (`jqcpp`) that reads a filter and a JSON
  document from stdin and prints each result as compact JSON.

The supported language is specified in `problems/jq/SPEC.md` (paths, `?`,
arithmetic, comparison, `and`/`or`, `if`, `as` bindings, `reduce`, array and
object construction, and the builtins `empty error not length keys has type
add select map sort sort_by group_by unique reverse min max tostring tonumber`).

## Layout

```
include/jq/      public headers
  value.hpp        Value (immutable, shared), Object / ObjectBuilder, compare()
  json.hpp         parse_json, write_json, to_json
  filter.hpp       Filter::compile / run / collect, jq::evaluate
  error.hpp        Error, JsonError, ParseError, RuntimeError
  jq.hpp           umbrella header
src/             implementation
  value.cpp        values, insertion-ordered objects, total ordering
  json.cpp         recursive-descent JSON parser, serialiser, number printing
  parser.cpp       filter lexer and recursive-descent parser -> syntax tree (ast.hpp)
  interpreter.cpp  tree-walking evaluator; streams via callbacks
  ops.cpp          arithmetic, indexing/slicing and builtin helpers
  filter.cpp       the public Filter API
cli/main.cpp     command-line tool
tests/           GoogleTest unit tests
build.sh run.sh  convenience scripts
```

### Design notes

* Values are immutable and reference-counted: copying, binding, indexing and
  iterating are O(1); `+`/`*` on arrays and objects cost O(|a|+|b|).
* Objects keep insertion order, with an open-addressing index built lazily for
  objects of more than 8 keys; sorted key order is computed at most once per
  object.
* The evaluator pushes outputs through callbacks in the order jq defines
  (the right operand of a binary operator is the outer loop, etc.). Errors are
  C++ exceptions, so results produced before an error have already been
  delivered. `try`/`?` only swallows errors raised by the term it marks, not
  by the downstream consumer.
* Sorting is a stable comparison sort with one key evaluation per element.

## Build

Requires a C++20 compiler and CMake ≥ 3.20; GoogleTest for the tests.

```sh
./build.sh                       # Release build into ./build
# or manually:
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build           # run the unit tests
```

Options: `-DJQCPP_BUILD_TESTS=OFF` (no GoogleTest needed),
`-DJQCPP_BUILD_CLI=OFF`.

## Command-line usage

Standard input is the filter (first line) followed by exactly one JSON
document. Every result is printed as one line of compact JSON. If evaluation
fails, the results produced so far are printed, then a line `error`. The exit
status is always 0.

```sh
$ printf '%s\n%s' '.users | map(select(.age >= 30)) | map(.name)' \
    '{"users":[{"name":"ann","age":31},{"name":"bob","age":25}]}' | ./run.sh
["ann"]

$ printf '%s\n%s' '.[] | .a?, 1' '[{"a":1},5]' | ./run.sh
1
1
1
```

## Library usage

```cpp
#include <iostream>
#include "jq/jq.hpp"

int main() {
  // One-shot helper: every output as compact JSON text.
  for (const std::string& line :
       jq::evaluate("[.[] | select(. > 1)], add", "[1,2,3]"))
    std::cout << line << '\n';             // [2,3]  then  6

  // Compile once, run many times, work with Values directly.
  jq::Filter f = jq::Filter::compile("group_by(.k) | map({k: .[0].k, n: length})");
  jq::Value doc = jq::parse_json(R"([{"k":"a"},{"k":"b"},{"k":"a"}])");
  try {
    f.run(doc, [](const jq::Value& v) { std::cout << jq::to_json(v) << '\n'; });
  } catch (const jq::RuntimeError& e) {
    std::cerr << "jq error: " << e.what() << '\n';
  }
}
```

Link against the `jqcpp::jqcpp` target (`target_link_libraries(app PRIVATE jqcpp)`
when using `add_subdirectory`).

Exceptions: `jq::ParseError` (bad filter), `jq::JsonError` (bad document),
`jq::RuntimeError` (evaluation error); all derive from `jq::Error`.
