# jq (subset) — a C++17 library and command-line tool

A from-scratch interpreter for a subset of the [`jq`](https://jqlang.github.io/jq/)
filter language, with jq 1.7 semantics (`jq -c`). It contains its own JSON
parser, JSON serializer and filter interpreter, and depends only on the C++
standard library (GoogleTest is used for the tests).

## Layout

| Path | Contents |
|---|---|
| `include/jq/value.hpp` | Immutable, reference-counted `Value`; insertion-ordered `Object`; `ObjectBuilder`; jq's total ordering (`compare`) |
| `include/jq/json.hpp` | `parse_json`, `write_json` / `to_json` |
| `include/jq/filter.hpp` | `Filter::compile`, `Filter::run`, `Filter::run_all`, `run_to_text` |
| `include/jq/error.hpp` | `JsonError`, `SyntaxError`, `EvalError` |
| `include/jq/jq.hpp` | umbrella header |
| `src/parser.cpp` | lexer + recursive-descent parser → syntax tree |
| `src/interpreter.cpp` | tree-walking evaluator (continuation-passing, lazy streams) |
| `src/ops.cpp` | arithmetic, indexing, slicing and the value-level builtins |
| `src/value.cpp`, `src/json.cpp` | value model, JSON I/O |
| `cli/main.cpp` | the command-line tool |
| `tests/` | GoogleTest unit tests |

## Building

Requires a C++17 compiler and CMake ≥ 3.20 (GoogleTest for the tests).

```sh
./build.sh                 # Release build into ./build
build/tests/jq_tests       # run the unit tests (or: ctest --test-dir build)
```

Or by hand: `cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build`.
Pass `-DJQ_BUILD_TESTS=OFF` to skip the tests (and the GoogleTest dependency).

## Command-line use

`./run.sh` (the executable is `build/jq`) reads **all of stdin**: the first line
is the filter, everything after the first newline is one JSON document. Every
result is printed as one line of compact JSON. If evaluation raises an error
that is not caught by `?`, the results produced before it are printed, then a
line `error`. The exit status is always 0.

```console
$ printf '%s\n%s' '.users | map(select(.age >= 30)) | sort_by(.age) | map(.name)' \
    '{"users":[{"name":"ann","age":31},{"name":"bob","age":25},{"name":"cy","age":30}]}' | ./run.sh
["cy","ann"]
```

## The language

Identity and paths (`.`, `.a`, `."a b"`, `.[k]`, `.[]`, `.[a:b]`, with `?`),
literals, `|`, `,`, arithmetic (`+ - * / %`), comparisons, `and`/`or`,
unary `-`, array and object construction (including `{a}`, `{$x}`, `{(e): v}`),
`if/elif/else/end`, `E as $x | body`, `reduce SRC as $x (INIT; UPDATE)`, `?`
(optional/try) and the builtins `empty error error(f) not length keys has(k)
type add select(f) map(f) sort sort_by(f) group_by(f) unique reverse min max
tostring tonumber`.

Semantics worth knowing: values are doubles; objects keep insertion order
(`keys` sorts); for a binary operator the right operand is the outer loop
(`[(1,2) + (10,20)]` is `[11,12,21,22]`); `.a?` tolerates only that one
operation while `(expr)?` is `try`. Numbers print as integers when integral,
otherwise in the shortest round-tripping form. There is no string
interpolation, no `def`, no paths/assignment, and no regex.

## Using the library

Link against the `jq::jq` CMake target (e.g. `add_subdirectory(jq)`
then `target_link_libraries(app PRIVATE jq::jq)`).

```cpp
#include <iostream>
#include "jq/jq.hpp"

int main() {
  jq::Value doc = jq::parse_json(R"({"users":[{"name":"ann","age":31},{"name":"bob","age":25}]})");

  // Compile once, run many times.
  jq::Filter f = jq::Filter::compile(".users | map(select(.age > 30) | .name)");
  for (const jq::Value& v : f.run_all(doc))      // throws jq::EvalError on failure
    std::cout << jq::to_json(v) << "\n";           // ["ann"]

  // Streaming, with access to results produced before an error.
  jq::Filter g = jq::Filter::compile(".users[] | .name, error");
  jq::RunStatus st = g.run(doc, [](const jq::Value& v) {
    std::cout << jq::to_json(v) << "\n";
    return true;                                   // return false to stop early
  });
  if (!st.ok) std::cerr << "error: " << st.error << "\n";

  // Building values directly.
  jq::ObjectBuilder b;
  b.set("k", jq::Value::number(1));
  jq::Value obj = b.build();                       // {"k":1}
}
```

`Filter::compile` throws `jq::SyntaxError`, `parse_json` throws `jq::JsonError`.
`Value`s are immutable and share storage when copied (O(1)); they are not safe to
share between threads.

## Design notes

* Evaluation is continuation-passing: each node calls a sink once per output
  and stops as soon as a sink returns `false`. Errors are propagated as a
  `false` return (no C++ exceptions on the hot path), and `try`/`?` tells
  errors raised inside its body from errors raised by its consumer.
* Variables live in a stack-allocated linked environment.
* Object lookup is a linear scan for small objects and a lazily built hash
  index for larger ones; the sorted key order is computed at most once per
  object. `add` accumulates in place, so it is linear in the total size.
* `sort_by`/`group_by` evaluate their key expression once per element and use
  a stable comparison sort.
