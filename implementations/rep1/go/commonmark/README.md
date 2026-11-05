# commonmark

A CommonMark-to-HTML converter written in Go, using only the standard
library. It reproduces the output of the reference implementation
[cmark](https://github.com/commonmark/cmark) 0.31.2 (default options, no
`--unsafe`) for a defined subset of CommonMark 0.31.2, and runs in linear
time and memory on the inputs that make naive implementations quadratic.

## Supported syntax

Thematic breaks, ATX and setext headings, indented and fenced code blocks,
paragraphs, block quotes, lists (tight and loose, nested), backslash
escapes, character references (numeric ones plus `&amp;` `&lt;` `&gt;`
`&quot;`), code spans, emphasis and strong emphasis with the full
delimiter-run rules, inline links and images (all destination and title
forms), autolinks, and hard and soft line breaks.

Not supported, because the input is assumed never to contain them: HTML
blocks, raw inline HTML, link reference definitions (and so reference
links), other named character references, and extensions such as tables.
A `<` that does not start an autolink is plain text.

## Building

Requires Go 1.27.1 or newer.

```sh
./build.sh          # or: go build -o bin/commonmark ./cmd/commonmark
```

This produces `bin/commonmark`. Run the tests with `go test ./...`.

## Command-line use

The tool reads the whole of standard input as UTF-8 Markdown and writes the
HTML to standard output. It takes no arguments and exits 0 on success.

```sh
./run.sh < README.md > README.html
printf '*hello*\n' | ./run.sh        # <p><em>hello</em></p>
```

## Library use

```go
package main

import (
	"fmt"
	"os"

	"example.com/commonmark"
)

func main() {
	// One-shot conversion.
	html := commonmark.ToHTML([]byte("# Hello\n\nSome *emphasis* and a [link](/url)."))
	fmt.Print(string(html))

	// Parse once, then render or stream the result.
	doc := commonmark.Parse([]byte("- a\n- b\n"))
	if _, err := doc.WriteTo(os.Stdout); err != nil {
		panic(err)
	}
}
```

The public API is:

| Function | Description |
| --- | --- |
| `ToHTML(src []byte) []byte` | Convert Markdown to HTML. |
| `ToHTMLString(src string) string` | The same for strings. |
| `Parse(src []byte) *Document` | Parse the block structure of a document. |
| `(*Document).HTML() []byte` | Render the document as HTML. |
| `(*Document).WriteTo(w io.Writer)` | Render and write with a single `Write`. |

## Layout

| File | Responsibility |
| --- | --- |
| `commonmark.go` | Public API and package documentation. |
| `block.go`, `blockparser.go` | Block tree and the line-by-line block parser (phase 1). |
| `scan.go` | In-place scanners for block starts (headings, fences, list markers, ...). |
| `inline.go` | Inline parser (phase 2): text, code spans, delimiter and bracket stacks, emphasis, links. |
| `linkscan.go` | Link destination, title and autolink scanners. |
| `entity.go` | Character references and backslash escapes. |
| `render.go`, `escape.go` | HTML rendering, escaping and URL encoding. |
| `chars.go` | ASCII character classes. |
| `cmd/commonmark` | The command-line tool. |
| `testdata/spec_examples.json` | CommonMark specification examples used by the tests. |

## Design notes

* The block parser works on bytes and keeps the open blocks as a chain;
  leaf blocks append each line to one buffer. Tabs are handled by column
  arithmetic, with partially consumed tabs expanded when text is added.
* Inline nodes live in a reusable arena addressed by integer indices and
  linked as sibling lists, so wrapping emphasis and links is O(1) per
  moved node. Inlines are parsed when their block is rendered, so only one
  block's inline tree exists at a time.
* The delimiter stack uses the twelve `openers_bottom` bounds, and code
  span closers are found with a per-length memo of backtick runs; both keep
  pathological inputs linear.
* Inline trees are rendered iteratively, so nesting depth is not limited by
  the call stack.
