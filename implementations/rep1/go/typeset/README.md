# typeset

`typeset` is a typesetting engine for *Codexa*, a small invented markup
language. It reads a document and an optional settings file and lays the text
out on numbered pages using total-fit line breaking, Liang hyphenation,
footnotes, floating figures, tables, a generated table of contents and
running headers and footers. The output is an exact, integer-only description
of every placed item (no floating point is used anywhere, so output is
byte-for-byte reproducible).

It is a Go library plus a thin command-line tool, using only the standard
library.

## Build

Requires Go 1.27 or later.

```sh
./build.sh          # builds bin/typeset
go test ./...       # unit tests
```

## Command line

```
typeset <input directory> <output directory>
```

* The input directory holds `document.cdx` (required) and `settings.cfg`
  (optional).
* Font metrics (`data/faces/*.cfm`) and hyphenation patterns
  (`data/hyphen/*.chp`) are read from a `data` directory **relative to the
  current working directory**.
* On success `layout.txt` (every placed text run, rule and box, page by page)
  and `report.txt` (counters such as lines, pages and total demerits) are
  written to the output directory.
* An invalid document or settings file produces a single `error.txt` with one
  line, `<file>:<line>:<col>: <code>`, and no other output. The exit status
  is still 0; it is non-zero only for usage errors or unreadable data files.

`run.sh` wraps the binary and can be called from any directory:

```sh
./run.sh path/to/input path/to/output
```

## Library layout

| package | responsibility |
|---|---|
| `typeset` | façade: `LoadResources`, `Typeset(Input, *Resources) *Result` |
| `units` | floor division, `Scale`, length/integer literals, roman and alphabetic numerals |
| `diag` | the located input error type (`file:line:col: code`) |
| `metrics` | `.cfm` font metric files: advances, kerns, glue and vertical metrics |
| `hyphen` | `.chp` pattern files and Liang's algorithm with exceptions |
| `settings` | `settings.cfg` parser, defaults, ranges and derived geometry |
| `markup` | Codexa parser: block tree with inline text resolved into styled units |
| `layout` | horizontal lists, line breaking, line setting, vertical lists, tables, footnotes, floats, page breaking, TOC, headers |
| `render` | formats `layout.txt` and `report.txt` |

The pipeline is strictly layered: `settings` and `markup` validate the input
and report the first error; `layout` builds each horizontal list once, breaks
it with a total-fit algorithm over prefix sums, flattens the block tree into
one vertical list, paginates the body, then builds and paginates the table of
contents; `render` sorts and prints the items.

## Using the library

```go
package main

import (
	"fmt"
	"os"

	"typeset"
)

func main() {
	res, err := typeset.LoadResources("data") // data/faces and data/hyphen
	if err != nil {
		panic(err)
	}
	out := typeset.Typeset(typeset.Input{
		Document:    []byte("@h1 Hello\nThe quick brown fox jumps over the lazy dog.\n"),
		HasDocument: true,
		Settings:    []byte("page-width = 200pt\npage-height = 120pt\n"),
		HasSettings: true,
	}, res)
	if out.Err != nil { // invalid input: out.Err is a *diag.Error
		fmt.Fprint(os.Stderr, out.ErrorText())
		return
	}
	fmt.Print(out.Layout) // contents of layout.txt
	fmt.Print(out.Report) // contents of report.txt
}
```

Lower-level pieces are importable too: `markup.Parse` returns the block tree,
`settings.Parse` the resolved settings, and `layout.Layout` the placed pages
(`layout.Result`), which `render.Layout` and `render.Report` format.

## Tests

`go test ./...` runs the unit tests of every package. The end-to-end tests in
the root package use the real font and pattern files and are skipped unless
they can be found at `../problems/typeset/data` or in the directory named by
`TYPESET_DATA`.
