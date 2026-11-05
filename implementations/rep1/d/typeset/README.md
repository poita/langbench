# typeset

A typesetting engine for the *Codexa* markup language, written in D.

It reads a Codexa document and an optional settings file, lays the text out on
numbered pages — total-fit (Knuth–Plass style) line breaking, Liang
hyphenation, lists, tables, footnotes, floating figures, a generated table of
contents, running headers and footers — and writes a complete, deterministic
description of every placed item. All arithmetic is exact integer arithmetic in
millipoints, so two correct implementations produce byte-identical output.

The project is a reusable library (`typeset`) plus a thin command-line tool
(`typeset:cli`). It depends only on the D standard library.

## Building

Requires LDC (tested with 1.41.0) and dub (tested with 1.40.0).

```sh
./build.sh          # dub build -b release --compiler=ldc2 :cli  ->  bin/typeset
dub test --compiler=ldc2   # run the unit tests
```

## Command-line use

```sh
./run.sh <input directory> <output directory>
# or:  bin/typeset [--data DIR] <input directory> <output directory>
```

* The input directory holds `document.cdx` (required) and `settings.cfg`
  (optional).
* Font metrics (`data/faces/*.cfm`) and hyphenation patterns
  (`data/hyphen/*.chp`) are read from a `data` directory resolved relative to
  the **current working directory** (override with `--data DIR`).
* On success the output directory receives `layout.txt` (every placed text run,
  rule and frame, page by page) and `report.txt` (counters such as pages,
  lines, total demerits).
* On invalid input it receives a single `error.txt` containing
  `<file>:<line>:<col>: <code>`. The exit status is still 0; only I/O failures
  (for example missing data files) exit non-zero.

The input language, the settings keys, the algorithms and the exact output
format are defined by the problem's `SPEC.md`.

## Library example

```d
import std.stdio;
import typeset;

void main()
{
    Input input;
    input.document = "@h1 Hello\nThe quick brown fox jumps over the lazy dog.\n";
    input.hasDocument = true;
    // input.settings = "page-width = 200pt\n"; input.hasSettings = true;

    // Fonts and hyphenation patterns come from a directory with faces/ and hyphen/.
    auto result = typesetDocument(input, new DirectoryData("data"));
    if (result.ok)
        write(result.layout);   // result.report holds the counters
    else
        write(result.error);    // "document.cdx:2:1: unknown-inline\n", ...
}
```

`DataSource` is an interface, so fonts and patterns can also be supplied from
memory (the unit tests do this with a synthetic font). The lower layers are
usable on their own:

```d
auto settings = parseSettings("tolerance = 500\n");        // typeset.settings
auto doc = parseDocument("A paragraph with {b|bold}.\n");   // typeset.markup
auto patterns = PatternSet.parse(chpText);                  // typeset.hyphen
auto breaks = patterns.hyphenate("typesetting");            // [7, 8] with the English set
```

## Layout of the code

| module | responsibility |
|---|---|
| `typeset.arith` | floor division, glyph scaling, numerals, exact badness and fitness |
| `typeset.errors` | error codes, `Diagnostic`, `TypesetError` |
| `typeset.values` | length/integer literals, `key = value` lines, column arithmetic |
| `typeset.fonts` | `.cfm` metrics, the nine-face table, box measurement |
| `typeset.hyphen` | `.chp` pattern sets, trie-based Liang algorithm with memoisation |
| `typeset.settings` | the 126-key settings table and the `settings.cfg` parser |
| `typeset.markup` | block tree, inline scanner, document parser and its error order |
| `typeset.hlist` | horizontal lists: fragments, glue, sentence rule, hyphenation points, prefix sums |
| `typeset.linebreak` | two-pass total-fit line breaking over the prefix sums |
| `typeset.setline` | glue distribution, alignment, output runs, line metrics |
| `typeset.layout` | block layout into the vertical list: spacing, headings, lists, tables, figures, footnotes, TOC |
| `typeset.page` | break legality, page scan, float zone, footnote area and splitting, headers/footers |
| `typeset.output` | output buffer and the sorted per-page item lists |
| `typeset.engine` | the pipeline: `typesetDocument` / `typesetDirectory` |
| `cli/source/app.d` | the command-line tool |

Unit tests live in `tests/` (separate from the library sources) and run with
`dub test`.
