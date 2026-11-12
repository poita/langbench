# commonmark

A small C++17 library and command-line tool that converts a **subset of
CommonMark 0.31.2** to HTML, producing the same output as the reference
implementation [`cmark`](https://github.com/commonmark/cmark) 0.31.2 with
default options. It is written from scratch using only the standard library.

Supported: thematic breaks, ATX and setext headings, indented and fenced code
blocks, paragraphs, block quotes, lists (tight and loose), backslash escapes,
entity references (`&amp; &lt; &gt; &quot;` and numeric ones), code spans,
emphasis and strong emphasis (full delimiter-run rules), inline links and
images, autolinks, and hard/soft line breaks.

Not supported (the input is assumed not to contain them): HTML blocks and raw
inline HTML, link reference definitions and reference links, other named
entities, and all extensions. A `<` that does not start an autolink and a
`[...]` not followed by `(` are plain text.

## Design

It follows cmark's two-phase algorithm:

1. **Block phase** (`src/block_parser.cpp`): reads the input line by line,
   matches each line against the chain of open blocks, opens new blocks, and
   adds the rest of the line to the open leaf (or to a lazy continuation).
   Cost O(N + L·D) for N bytes, L lines and nesting depth D.
2. **Inline phase** (`src/inline_parser.cpp`): parses each paragraph and
   heading left to right with a delimiter stack, a bracket stack and the
   process-emphasis algorithm (`openers_bottom` bounds, so no rescans), plus a
   memo for code-span searches. Linear per block.
3. **Rendering** (`src/html_renderer.cpp`): one iterative walk over the tree.

Nodes live in one arena (`commonmark::Document`) and refer to each other by
index, so trees nested thousands of levels deep are parsed, rendered and
destroyed without recursion.

| Module | Responsibility |
| --- | --- |
| `include/commonmark/node.h`, `src/node.cpp` | tree types and tree surgery |
| `include/commonmark/parser.h`, `src/parser.cpp` | `parse()` |
| `src/block_parser.cpp` | phase 1 |
| `src/inline_parser.cpp` | phase 2 |
| `src/text_util.*` | character classes, entities, escapes (internal) |
| `include/commonmark/html.h`, `src/html_renderer.cpp` | `render_html()` |
| `include/commonmark/commonmark.h` | umbrella header, `to_html()` |
| `cli/main.cpp` | the command-line tool |

## Building

Requires a C++17 compiler and CMake 3.20+; the unit tests need GoogleTest.

```sh
./build.sh                 # Release build into ./build (library, CLI, tests)
(cd build && ctest)        # run the unit tests
```

or by hand:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

CMake options: `COMMONMARK_BUILD_CLI` (default ON) and
`COMMONMARK_BUILD_TESTS` (default ON; skipped with a warning if GoogleTest is
not found). `cmake --install build` installs the library, headers and CLI.

## Command-line tool

`commonmark-cli` reads Markdown from standard input (the whole input is the
document, UTF-8, LF line endings) and writes the HTML to standard output. It
exits 0 on success. File arguments are accepted too (`-` means stdin).

```sh
echo '# Hello *world*' | ./run.sh
# <h1>Hello <em>world</em></h1>
```

`run.sh` locates the built binary relative to itself, so it works from any
directory.

## Using the library

```cpp
#include <commonmark/commonmark.h>
#include <iostream>

int main() {
  // One call:
  std::cout << commonmark::to_html("Some *emphasis* and a [link](/url).\n");

  // Or parse once and inspect or render the tree:
  commonmark::Document doc = commonmark::parse("# Title\n\n- a\n- b\n");
  for (commonmark::NodeId id = doc[doc.root()].first_child; id != commonmark::kNoNode;
       id = doc[id].next) {
    if (doc[id].type == commonmark::NodeType::Heading) {
      std::cout << "heading level " << doc[id].level << "\n";
    }
  }
  std::cout << commonmark::render_html(doc);
}
```

Link against the `commonmark::commonmark` target:

```cmake
add_subdirectory(commonmark)
target_link_libraries(my_app PRIVATE commonmark::commonmark)
```

## Tests

`tests/` holds GoogleTest suites for blocks, inlines, links and images,
rendering (including the worked examples), the public tree API, stress inputs
that must not behave quadratically, and a table of the CommonMark specification
examples that fall in the supported subset
(`tests/spec_examples_data.inc`; the examples are © John MacFarlane,
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/)).
