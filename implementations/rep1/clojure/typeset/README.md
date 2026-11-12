# typeset — the Codexa typesetting engine

`typeset` reads a *Codexa* document (a small invented markup language) and an
optional `settings.cfg`, lays the document out on numbered pages and writes a
complete, byte-exact description of every placed text run, rule and box. It
implements:

* Knuth–Plass **total-fit line breaking** (two passes, exact integer arithmetic),
* Liang **hyphenation** with pattern and exception files,
* kerned glyph metrics from `.cfm` font-metric files,
* ragged and justified alignment, headings, nested lists, block quotes,
  preformatted text and tables with a column-width algorithm,
* footnotes (with splitting across pages) and floating figures,
* page breaking with widows, orphans and keep-with-next,
* a generated table of contents with leaders and roman-numbered front pages,
* running headers and footers with placeholders.

Everything is integer arithmetic (lengths are millipoints), so the output is
deterministic and byte-identical across implementations. The behaviour is
specified in `problems/typeset/SPEC.md`; the design follows
`problems/typeset/APPROACH.md`.

It is plain Clojure 1.12 with no dependencies beyond the standard library
(tests additionally use `test.check`).

## Building

```sh
./build.sh
```

fetches the dependencies and AOT-compiles the command-line entry point into
`classes/` (so start-up is quick). Building is optional: without it
`run.sh` still works, it just compiles from source on every run.

Requires the `clojure` CLI and a JDK (developed with Clojure 1.12.6 on
Java 27).

## Command line

```sh
./run.sh <input directory> <output directory>
```

* The input directory holds `document.cdx` (required) and `settings.cfg`
  (optional).
* Font metrics and hyphenation patterns are read from `data/faces/*.cfm` and
  `data/hyphen/*.chp` **relative to the current directory**.
* On success the output directory receives `layout.txt` (every page and every
  placed item) and `report.txt` (counters such as pages, lines and total
  demerits).
* An invalid document produces just `error.txt`, containing one line
  `<file>:<line>:<col>: <code>`. The exit status is 0 in both cases.

Example:

```sh
mkdir -p /tmp/in /tmp/out
printf 'The quick brown fox.\n' > /tmp/in/document.cdx
cd problems/typeset && ../../typeset/run.sh /tmp/in /tmp/out
cat /tmp/out/layout.txt
# layout 1
# pages 1
# page 1 1 612000 792000 72000 72000 468000 648000
#   text body serif 10000 90000 79310 15630 "The"
#   ...
```

## Library

The public API is in `typeset.core`:

```clojure
(require '[typeset.core :as ts])

(def data (ts/load-data "data"))           ; faces + hyphenation patterns

;; in-memory: document text, settings text (or nil), loaded data
(ts/typeset-strings "The quick brown fox.\n"
                    "page-width = 200pt\npage-height = 120pt\n"
                    data)
;; => {"layout.txt" "layout 1\npages 1\n..." "report.txt" "report 1\n..."}
;;    or {"error.txt" "document.cdx:2:1: unknown-inline\n"}

;; from a directory, writing the result to another
(ts/write-outputs! "out" (ts/typeset "in" {:data-dir "data"}))
```

`typeset-strings` and `typeset` return a map from output file name to its
text, so callers decide where (and whether) to write it.

### Modules

| namespace | responsibility |
|---|---|
| `typeset.core` | the pipeline and public API |
| `typeset.cli` | the command-line tool |
| `typeset.settings` | `settings.cfg` parsing, validation, defaults, geometry |
| `typeset.parser` | the Codexa block parser and its error codes |
| `typeset.inline` | the inline scanner (styles, escapes, footnotes) |
| `typeset.metrics` / `typeset.hyphenation` | `.cfm` and `.chp` files, glyph measurement, Liang's algorithm |
| `typeset.hlist` | horizontal lists: fragments, glue, hyphenation points, marks |
| `typeset.linebreak` | total-fit line breaking with O(1) line measurement |
| `typeset.line` | glue distribution, alignment, run merging, line metrics |
| `typeset.text` | break + set one piece of text and record statistics |
| `typeset.table` | table cell measurement, column widths, rows |
| `typeset.vlist` | vertical items, space registers, the baseline rule |
| `typeset.layout` | the block-tree walk: contexts, headings, lists, figures |
| `typeset.paginate` | page breaking, floats and footnote areas |
| `typeset.toc` / `typeset.page` | table of contents, running headers/footers |
| `typeset.out` | output items, formatting and sort order |
| `typeset.util` | floor division, `scale`, numerals, error type |

## Tests

```sh
clojure -M:test
```

runs the Cognitect test-runner over `test/`: unit tests for each module,
the worked examples of the specification end to end, `test.check` properties
(exact badness arithmetic, text preservation, determinism) and — when the
`problems/typeset/tests` corpus is next to the project — every corpus case
in-process. `test-resources/data` holds a copy of the font and pattern files
for the standalone tests.

The full acceptance run from the repository root is

```sh
typeset/build.sh && python3 run_tests.py typeset -- typeset/run.sh
```
