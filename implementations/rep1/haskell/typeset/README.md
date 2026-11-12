# typeset

A typesetting engine for *Codexa*, a small invented markup language. It reads a
Codexa document (and an optional settings file), lays it out on numbered pages
and writes a complete, exact description of every placed item:

* total-fit (Knuth–Plass style) line breaking in two passes,
* Liang hyphenation with pattern files and exceptions,
* justified / ragged / centred text, headings, nested lists, quotes, tables,
  preformatted text,
* footnotes (including splitting across pages) and floating figures,
* a generated table of contents with leaders, and running headers/footers.

Everything is integer arithmetic (lengths are millipoints), so the output is
byte-for-byte reproducible. The format of the input, the algorithms and the
output are specified in the problem's `SPEC.md`; the code follows that
specification section by section.

## Building

Requires GHC 9.14 and cabal 3.18. Only GHC's bundled packages are used
(`base`, `containers`, `array`, `filepath`, `directory`); the test suite
additionally uses `hspec` and `QuickCheck`.

```
./build.sh          # cabal build, then copies the executable to bin/typeset
cabal build all     # the same, plus the library and the test suite
cabal test          # run the unit, property and golden tests
```

## Command-line use

```
./run.sh <input directory> <output directory>
# or:  typeset [--data DIR] <input directory> <output directory>
```

The input directory holds `document.cdx` (required) and `settings.cfg`
(optional). Fonts and hyphenation patterns are read from a `data` directory
(`data/faces/*.cfm`, `data/hyphen/*.chp`) resolved **relative to the current
working directory** (override with `--data DIR`); a copy of the supplied data
files is in `data/` of this repository.

On success the output directory receives

* `layout.txt` – the pages and every placed `text`, `rule` and `box` item,
* `report.txt` – counters (pages, lines, demerits, ...).

If the input is invalid, exactly one file, `error.txt`, is written instead,
holding one line `<file>:<line>:<col>: <code>`. The exit status is 0 in both
cases.

Example (`document.cdx`: `The quick brown fox.`):

```
$ mkdir in out && echo 'The quick brown fox.' > in/document.cdx
$ ./run.sh in out && cat out/layout.txt
layout 1
pages 1
page 1 1 612000 792000 72000 72000 468000 648000
  text body serif 10000 90000 79310 15630 "The"
  text body serif 10000 108170 79310 22240 "quick"
  text body serif 10000 132950 79310 25140 "brown"
  text body serif 10000 160630 79310 15810 "fox."
```

## Library use

The `Typeset` module is the public entry point:

```haskell
import Typeset

main :: IO ()
main = do
  res <- loadResources "data"            -- fonts + hyphenation patterns
  case typeset res Nothing (Just "The quick brown fox.\n") of
    Left err  -> putStrLn (renderError err)          -- e.g. "document.cdx:2:1: unknown-inline"
    Right out -> putStr (outLayout out) >> putStr (outReport out)
```

`typeset res settingsText documentText` is pure: it takes the contents of
`settings.cfg` (`Nothing` for the defaults) and `document.cdx` (`Nothing`
reports `missing-document`) and returns the two rendered files or the first
error. `runDirectory` implements the file-level contract used by the CLI.

### Module map

| module | responsibility |
|---|---|
| `Typeset` | public API: `loadResources`, `typeset`, `runDirectory` |
| `Typeset.Units` | `scale`, size steps, roman / alphabetic numerals, exact `100·d³/Y³` |
| `Typeset.Font` | `.cfm` metric files, face resolution, box widths with kerning |
| `Typeset.Hyphenation` | `.chp` pattern files and Liang's algorithm |
| `Typeset.Settings` | the settings file: value types, key table, derived geometry |
| `Typeset.Error` | error codes and the `error.txt` line |
| `Typeset.Syntax`, `Typeset.Parser`, `Typeset.Parser.Inline` | the block tree, the line-based parser with its error precedence, the inline scanner |
| `Typeset.HList` | inline text → styled characters → fragments → boxes, glue and penalties |
| `Typeset.Break` | O(1) line measurement from prefix sums, two-pass total-fit breaking |
| `Typeset.Line` | glue distribution, alignment, output runs, line metrics |
| `Typeset.Layout`, `Typeset.Layout.*` | block tree → vertical list (spacing registers, headings, lists, tables, figures, footnotes, table of contents) |
| `Typeset.Page` | break legality, the per-page cut scan, footnote splitting, float placement |
| `Typeset.Header` | running headers and footers |
| `Typeset.Output` | `layout.txt` / `report.txt` rendering and the item sort |

## Tests

`cabal test` runs an hspec suite:

* unit tests for the arithmetic helpers, settings and document parsing
  (including the documented error positions), Liang hyphenation, line
  breaking and glue distribution, and table column widths;
* QuickCheck properties (numeral round trips, exact cubic badness, justified
  lines filling the measure, column widths summing to the available width);
* golden tests: every directory under `test/golden/` is an `input/` plus the
  `expected/` output and is run through the library.
