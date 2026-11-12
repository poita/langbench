# typeset — the Codexa typesetting engine

`typeset` reads a *Codexa* document (a small invented markup language) and an
optional settings file, lays the document out on numbered pages, and writes an
exact, integer-only description of every placed text run, rule and box.

It implements:

- total-fit (Knuth–Plass) line breaking with two passes and exact 128-bit
  badness arithmetic;
- Liang hyphenation with pattern sets, exceptions and explicit `\-` points;
- justified, left, right and centred lines with floor-division glue
  distribution;
- headings, nested lists, block quotes, `@block` overrides, preformatted text
  and tables with automatic column widths;
- footnotes that may split across pages, floating figures with captions, widow,
  orphan and keep-with-next control;
- a generated table of contents with leaders, roman-numbered front pages and
  running headers and footers with placeholders.

Everything is integer arithmetic (lengths are millipoints), so output is
byte-for-byte reproducible. Only the Go standard library is used.

## Building

```
./build.sh          # builds bin/typeset with `go build`
go test ./...       # runs the unit and golden tests
```

Go 1.27 or later is required.

## Command line

```
typeset <input directory> <output directory>
```

The input directory holds `document.cdx` and, optionally, `settings.cfg`. The
output directory receives:

- `layout.txt` and `report.txt` for a valid document, or
- `error.txt` (one line, `<file>:<line>:<col>: <code>`) for an invalid one.

The exit status is 0 in both cases; a nonzero status means an I/O failure.
Font metrics and hyphenation patterns are read from `data/faces/*.cfm` and
`data/hyphen/*.chp` **relative to the current working directory**; a copy of
the data files is in this repository's `data/` directory, so run the tool from
the project root (`./run.sh` simply executes `bin/typeset`):

```
./build.sh
mkdir -p /tmp/out
./run.sh testdata/001_ex_05_one_line/input /tmp/out
cat /tmp/out/layout.txt
```

```
layout 1
pages 1
page 1 1 200000 120000 20000 20000 160000 80000
  text body serif 10000 38000 27310 15630 "The"
  ...
```

Each `text` line is `text <region> <face> <size> <x> <y> <width> "<string>"`;
see the specification for the complete `layout.txt` and `report.txt` formats.

## Library

The engine is a set of small packages with one responsibility each:

| package | responsibility |
|---|---|
| `typeset` | top-level entry point: files in, output files out |
| `dim` | floor division, `scale`, length and integer literals |
| `diag` | the located input error type and its codes |
| `metric` | font metric (`.cfm`) loading, face resolution, text measurement |
| `hyphen` | Liang pattern (`.chp`) loading and hyphenation points |
| `settings` | `settings.cfg` parsing, defaults, ranges, error positions |
| `codexa` | the markup parser; produces a block tree with resolved inline text |
| `hlist` | horizontal lists (boxes, glue, penalties) and line setting |
| `linebreak` | the total-fit line breaker |
| `layout` | vertical lists, tables, footnotes, figures, pagination, TOC, headers |
| `render` | `layout.txt`, `report.txt` and `error.txt` formatting |
| `numeral` | roman and alphabetic numerals |

The simplest use is the top-level function, which works on any `fs.FS`:

```go
package main

import (
	"fmt"
	"os"
	"testing/fstest"

	"typeset"
)

func main() {
	input := fstest.MapFS{
		"document.cdx": {Data: []byte("@h1 Hello\nThe quick brown fox jumps over the lazy dog.\n")},
		"settings.cfg": {Data: []byte("page-width = 200pt\npage-height = 120pt\nmargin-top = 20pt\nmargin-bottom = 20pt\nmargin-left = 20pt\nmargin-right = 20pt\n")},
	}
	out, err := typeset.Typeset(input, os.DirFS("data"))
	if err != nil {
		panic(err) // the data files could not be read
	}
	if out.Err != nil {
		fmt.Println("invalid input:", out.Err) // also in out.Files["error.txt"]
		return
	}
	fmt.Print(string(out.Files["layout.txt"]))
	fmt.Print(string(out.Files["report.txt"]))
}
```

The stages can also be used on their own. For example, to break one paragraph:

```go
faces, _ := metric.LoadSet(os.DirFS("data"), "faces")
env := &hlist.Env{Faces: faces, HyphenPenalty: 50, ExHyphenPenalty: 50, RaggedStretch: 3,
	MarkSize: 7000, MarkRaise: 3000}
b := hlist.NewBuilder(env, hlist.Context{
	Style: metric.Style{Family: metric.Serif}, Size: 10000, Align: hlist.Justify,
})
b.Inline(codexa.Literal("The quick brown fox jumps over the lazy dog."))
list := b.List()
res := linebreak.Break(list, 142000, 0, linebreak.Params{
	Tolerance: 1000, LinePenalty: 10, AdjDemerits: 10000,
	DoubleHyphenDemerits: 10000, FinalHyphenDemerits: 5000,
})
lines := hlist.SetLines(env, list, res.Breaks, hlist.Geometry{Left: 0, Measure: 142000})
```

## Layout of the repository

```
cmd/typeset/   the command-line tool
data/          font metrics and hyphenation patterns
testdata/      golden test cases (input/ and expected/ directories)
*/             the library packages listed above, each with its own tests
```

`TestGolden` in the root package runs every directory under `testdata/`
through the whole engine and compares the produced files with `expected/`.
