# typeset — the Codexa typesetting engine

`typeset` reads a *Codexa* document (a small invented markup language) and an
optional settings file, lays the document out on numbered pages — total-fit
(Knuth–Plass) line breaking, Liang hyphenation, footnotes, floating figures,
a generated table of contents and running headers/footers — and writes a
complete, integer-exact description of every placed item.

It is a C++20 library with a thin command-line tool on top. Only the standard
library is used (GoogleTest for the tests).

## Build

Requirements: a C++20 compiler (developed with Apple clang 21), CMake ≥ 3.20,
and GoogleTest for the tests.

```sh
./build.sh                       # Release build into ./build
ctest --test-dir build           # run the unit tests
# or, to skip the tests: cmake -S . -B build -DTYPESET_BUILD_TESTS=OFF
```

This produces `build/libtypeset.a` and the command-line tool `build/typeset`.

## Command line

```sh
./run.sh <input directory> <output directory>
```

* `<input>/document.cdx` is required; `<input>/settings.cfg` is optional.
* On success the output directory receives `layout.txt` (every page and every
  placed `text` / `rule` / `box` item) and `report.txt` (counters).
* If the input is invalid, the output directory receives a single
  `error.txt` holding one line `<file>:<line>:<col>: <code>`
  (`file` is `settings.cfg`, `document.cdx` or `-`).
* The exit code is 0 in every one of those cases; nonzero means an I/O or data
  problem (for example missing font files).
* Font metrics and hyphenation patterns are read from `data/faces/*.cfm` and
  `data/hyphen/*.chp` **relative to the current working directory**
  (set `TYPESET_DATA` to use another directory). A copy of the data set is in
  `data/` of this repository, so running from the project root works:

```sh
mkdir -p /tmp/in /tmp/out
printf 'The quick brown fox.\n' > /tmp/in/document.cdx
./run.sh /tmp/in /tmp/out && cat /tmp/out/layout.txt
```

The file formats (settings keys, the markup language, the output format) are
defined by the problem specification; the main points are:

* All quantities are integers: lengths are in millipoints (`1pt = 1000`),
  glyph metrics in thousandths of an em, and all division is floor division.
* `layout.txt` lists, per page, `text <region> <face> <size> <x> <y> <width> "<string>"`,
  `rule ...` and `box ...` lines sorted by region, `y`, `x`, kind and text.

## Library

The public headers live in `include/typeset/`; everything is in the namespace
`typeset`. The modules, in pipeline order:

| header | responsibility |
|---|---|
| `util.hpp` | floor division, `scale`, roman numerals, UTF-8 helpers |
| `error.hpp` | the positioned `Error` thrown for invalid input |
| `font.hpp` | `.cfm` metrics, `Face`, `FontSet`, face resolution |
| `hyphenation.hpp` | Liang patterns and exceptions (`PatternSet`) |
| `settings.hpp` | `Settings` and the `settings.cfg` parser |
| `document.hpp` | the Codexa parser: block tree with resolved inline text |
| `hlist.hpp` | horizontal lists: fragments, glue, hyphenation points, O(1) line measuring |
| `linebreak.hpp` | two-pass total-fit breaking and line setting (glue distribution, alignment, runs) |
| `layout.hpp` | block layout into the vertical list: spacing, lists, headings, tables, figures, footnotes, table of contents |
| `paginate.hpp` | page breaking: legal breaks, widows/orphans, keep-with-next, footnote splitting, float zones |
| `output.hpp` | `layout.txt` / `report.txt` formatting |
| `typeset.hpp` | the one-call entry point (`typeset::run`) |

### Example

```cpp
#include <iostream>
#include "typeset/typeset.hpp"

int main() {
    typeset::Input in;
    in.document = "@h1 Introduction\nThe quick brown fox jumps over the lazy dog.\n";
    in.settings = "page-width = 200pt\npage-height = 120pt\n"
                  "margin-left = 20pt\nmargin-right = 20pt\n"
                  "margin-top = 20pt\nmargin-bottom = 20pt\n";

    // `data` holds faces/*.cfm and hyphen/*.chp.
    typeset::Result r = typeset::run(in, "data");
    if (!r.ok) {
        std::cerr << r.error;          // e.g. "document.cdx:2:1: unknown-inline"
        return 1;
    }
    std::cout << r.layout << r.report;
    std::cout << "pages: " << r.stats.pages << "\n";
}
```

Callers that typeset many documents can load the data once with
`typeset::Resources::load("data")` and pass it to `typeset::run(input, resources)`.
The individual stages are usable on their own as well, for example
`typeset::Document::parse`, `typeset::Settings::parse`,
`typeset::HListBuilder::build` and `typeset::breakIntoLines`.

## Design notes

* **Pipeline.** Load faces and patterns → parse settings → parse the document
  into a block tree (inline text is resolved into units that reference a style
  tree) → walk the tree once, building each horizontal list, breaking it and
  appending vertical items → paginate the body → build and paginate the table
  of contents (no fixed-point iteration) → add headers/footers → format.
* **Line breaking.** Prefix sums of width, stretch, shrink and infinite-glue
  count make measuring any candidate line O(1). Pass 1 drops a node from the
  active set once its line is overfull; pass 2 evaluates every node at every
  breakpoint. Demerits and the cube in the badness use 128-bit intermediates.
* **Pagination.** Each page scans forward incrementally (cursor and footnote
  stack are updated per item), so a page costs time linear in the items it
  examines. Break legality is computed once per vertical list.
* Every list (paragraph, heading, table cell, caption, footnote, TOC entry) is
  built and broken exactly once.

## Tests

`tests/` contains GoogleTest suites per module (arithmetic, fonts,
hyphenation, settings, parser errors, line breaking) plus end-to-end tests of
the specification's worked examples. They run with `ctest --test-dir build`.
