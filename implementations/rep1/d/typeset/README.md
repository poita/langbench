# typeset

A typesetting engine for *Codexa*, a small invented markup language. It lays a
document out on numbered pages using total-fit (Knuth–Plass) line breaking,
Liang hyphenation, footnotes, floating figures, a generated table of contents
and running headers, and describes every placed item as text.

Everything is integer arithmetic (lengths are millipoints, division is floor
division), so output is exactly reproducible. The project is a reusable D
library (`source/typeset/`) with a thin command-line tool on top (`app/main.d`).
It uses only Phobos/druntime.

## Building

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh          # same as: dub build -b release --compiler=ldc2
```

This produces `build/typeset`. `run.sh <input dir> <output dir>` runs it from any
directory.

## Running the tests

```sh
dub test --compiler=ldc2
```

Tests are D `unittest` blocks next to the code they test, plus end-to-end tests
in `source/typeset/integration.d` that use a small synthetic font. Set
`TYPESET_DATA` to the shipped `data/` directory to also run a test against the
real font metrics.

## Command line

```
typeset <input directory> <output directory>
```

* The input directory holds `document.cdx` (required) and `settings.cfg`
  (optional).
* Font metrics (`data/faces/*.cfm`) and hyphenation patterns
  (`data/hyphen/*.chp`) are read from a `data` directory **relative to the
  current working directory**.
* On success the output directory receives `layout.txt` (every text run, rule
  and frame on every page) and `report.txt` (statistics: pages, lines,
  demerits, …).
* On invalid input it receives only `error.txt` with one line
  `<file>:<line>:<col>: <code>`. The exit status is 0 in both cases; it is
  nonzero only for usage errors or an unreadable `data` directory.

## Library overview

| module | responsibility |
|---|---|
| `typeset.units` | floor division, `scale`, roman numerals, exact badness ratio |
| `typeset.metrics` | `.cfm` font metrics, kerning, the nine faces |
| `typeset.hyphenation` | `.chp` patterns, Liang's algorithm |
| `typeset.settings` | the 126 settings, value parsers, range checks |
| `typeset.markup` | block parser and inline scanner, with spec-exact errors |
| `typeset.hlist` | horizontal lists: fragments, glue, hyphenation points |
| `typeset.linebreak` | total-fit breaking with O(1) line measurement |
| `typeset.line` | glue distribution, alignment, output runs |
| `typeset.vlist` | vertical items, space registers, vertical placement |
| `typeset.compose` | block layout: headings, lists, tables, figures, footnotes, TOC |
| `typeset.paginate` | page breaking: legality, footnote splitting, floats |
| `typeset.layout` | placed items, `layout.txt` / `report.txt` formats |
| `typeset.engine` | the pipeline: `typesetSources`, `typesetDirectory` |

The package module `typeset` re-exports the public API.

### Example

```d
import std.stdio : writeln;
import typeset;

void main()
{
    auto resources = Resources.load("data");        // faces + hyphenation patterns
    auto result = typesetSources(resources,
        "@h1 Greetings\nThe quick brown fox{n|A note.} jumps over the lazy dog.\n",
        "page-width = 300pt\npage-height = 300pt\n");   // settings.cfg text, or null
    if (result.ok)
    {
        foreach (page; result.layout.pages)
            foreach (item; page.items)
                writeln(page.label, ": ", item.format());
        writeln(result.report.toText());
    }
    else
        writeln(result.errorText());                    // e.g. "document.cdx:2:1: unknown-inline"
}
```

Add the library to another dub project with the `library` configuration
(`subConfiguration "typeset" "library"`).

## Design notes

* Every horizontal list is built and broken once (table cells are measured and
  broken from the same list). Line measurement uses prefix sums. Pass 1 of line
  breaking prunes overfull nodes for good; pass 2 is unpruned.
* `100 * d^3` can exceed 64 bits; `cubeRatio100` uses 128-bit arithmetic only
  when needed.
* The body is paginated once, then the table of contents, with no iteration.
