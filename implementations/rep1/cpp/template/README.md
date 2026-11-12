# jinjalite

A small Jinja2-style template engine in C++20, with no dependencies beyond the
standard library. It implements a well-defined subset of Jinja2 3.1
(`StrictUndefined`, no autoescape, no `trim_blocks`/`lstrip_blocks`):

- `{{ expr }}`, `{# comments #}`, and `-` whitespace control on every tag
- expressions: arithmetic (`+ - * / // % **`), `~`, comparisons (chained),
  `and`/`or`/`not`, `in`/`not in`, list literals, attribute and subscript
  access, calls, `is defined`
- thirteen filters: `upper lower trim escape replace length int join first last
  reverse sort default`
- statements: `if`/`elif`/`else`, `for`/`else` (with `loop`), `set`, `macro`,
  `include`, and template inheritance with `extends`, `block` and `super()`
- the builtin `range`

Rendering is all-or-nothing: any error is reported as one of five kinds
(`syntax`, `filter`, `undefined`, `template`, `type`) and no partial output is
produced.

## Layout

| Path | Contents |
|------|----------|
| `include/jinjalite/` | public headers (one per module) |
| `src/` | library implementation |
| `cli/main.cpp` | the command-line tool (a thin wrapper over the library) |
| `tests/` | GoogleTest unit and end-to-end tests |
| `build.sh`, `run.sh` | build and run helpers |

Library modules:

| Module | Responsibility |
|--------|----------------|
| `value` | dynamic `Value` (shared, immutable data) and insertion-ordered `Dict` |
| `format` | printing/repr of values, shortest round-trip float formatting |
| `ops` | truthiness, arithmetic, comparison, `in`, subscripts, sequence view |
| `filters` | the built-in filters |
| `json` | JSON parser producing `Value`s (int/float distinction, key order kept) |
| `lexer` | splits a template into text/tag items, whitespace control, tokenizes tags |
| `ast`, `parser` | syntax tree and recursive-descent parser (filter names checked at load) |
| `scope`, `interpreter` | lexical scopes and the tree-walking interpreter (macros, blocks, `super`) |
| `engine` | public API: `Engine`, plus parsing of the CLI document format |

Each template is lexed, parsed and checked at most once, the first time it is
needed. Values are shared rather than copied, scope creation is O(1), and
output is appended to one buffer (only macro calls and `super()` produce
separate strings).

## Building

Requires a C++20 compiler, CMake ≥ 3.20 and (for the tests) GoogleTest.

```sh
./build.sh                       # Release build into ./build
# or directly:
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build           # or ./build/tests/jinjalite_tests
```

Use `-DJINJALITE_BUILD_TESTS=OFF` to skip the tests (and the GoogleTest
requirement).

## Command-line usage

The tool reads a single document from stdin and writes to stdout:

```
<JSON context object, one or more lines>
--
=== <name>
<template body>
=== <name>
<template body>
```

The first template is rendered; the others are available to `include` and
`extends`. A body runs up to the LF before the next `=== ` header line (the
last one up to end of input, minus one trailing LF). On success the output is
the rendered text followed by `\n`; on failure it is the single line
`error: <kind>`. The exit status is 0 in both cases.

```sh
$ printf '{"user": {"name": "Ada"}, "n": 3}\n--\n=== main\nHi {{ user.name|upper }}! {{ n * 2 }}' | ./run.sh
Hi ADA! 6
```

## Library usage

```cpp
#include <iostream>
#include "jinjalite/engine.hpp"

int main() {
  jinjalite::Engine engine;
  engine.set_context_json(R"({"title": "Report", "items": [3, 1, 2]})");
  engine.add_template("page",
      "{% extends 'base' %}"
      "{% block body %}{% for i in items|sort %}{{ i }} {% endfor %}{% endblock %}");
  engine.add_template("base", "<h1>{{ title }}</h1>\n{% block body %}{% endblock %}");

  try {
    std::cout << engine.render("page") << "\n";   // <h1>Report</h1>\n1 2 3
  } catch (const jinjalite::Error& e) {
    std::cerr << "error: " << jinjalite::to_string(e.kind()) << "\n";
  }
}
```

Link against the `jinjalite` CMake target:

```cmake
add_subdirectory(jinjalite)
target_link_libraries(my_app PRIVATE jinjalite)
```

Contexts can also be built from `jinjalite::Value` objects
(`Value::integer`, `Value::string`, `Value::list`, `Value::dict`, ...) and
passed to `Engine::set_context`.

## Notes on the supported subset

The language is exactly the grammar described in the problem specification:
no dict literals, slices, conditional expressions, tuples, `{% raw %}`,
`import`, `call`/`with`/`filter` blocks, keyword filter arguments, or tests
other than `is defined`. Integers are 64-bit (arithmetic wraps rather than
promoting to big integers).
