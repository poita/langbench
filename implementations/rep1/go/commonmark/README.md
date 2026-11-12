# commonmark

A CommonMark-to-HTML converter in Go, using only the standard library. For the
supported subset of CommonMark 0.31.2 it produces the same HTML as the
reference implementation [cmark](https://github.com/commonmark/cmark) with its
default options.

It is a cmark-style two-phase converter: a block phase builds the tree of
block quotes, lists, headings, code blocks and paragraphs line by line; an
inline phase then parses the text of each paragraph and heading (delimiter
stack for emphasis, bracket stack for links and images, memoised code-span
search). Parsing and rendering run in linear time and never recurse on
inline nesting, so hostile inputs (thousands of nested brackets or emphasis
levels, megabytes of backticks) are handled quickly.

**Supported:** thematic breaks, ATX and setext headings, indented and fenced
code blocks, paragraphs, block quotes, lists, backslash escapes, entity
references (`&amp; &lt; &gt; &quot;` and numeric ones), code spans, emphasis,
inline links and images, autolinks, hard and soft line breaks.

**Not supported:** HTML blocks, raw inline HTML, link reference definitions
and reference links, other named entities, extensions (tables, strikethrough,
...). Such input is treated as ordinary text.

## Layout

| Path                | Responsibility                                              |
|---------------------|-------------------------------------------------------------|
| `commonmark.go`     | public API: `Parse`, `RenderHTML`, `ToHTML`                 |
| `ast/`              | document tree (`Node`, `Kind`), O(1) tree editing, `Walk`   |
| `block/`            | phase 1: block structure                                    |
| `inline/`           | phase 2: emphasis, links, code spans, autolinks, breaks     |
| `render/`           | HTML output                                                 |
| `internal/scan/`    | character classes, entity decoding, backslash unescaping    |
| `cmd/commonmark/`   | the command-line tool                                       |

## Build

Requires Go 1.27 or later.

```sh
./build.sh          # builds bin/commonmark
go test ./...       # runs the tests
```

## Command-line use

The tool reads a Markdown document from standard input and writes HTML to
standard output. It takes no arguments.

```sh
echo 'Some *emphasis* and a [link](/url "title").' | ./run.sh
# <p>Some <em>emphasis</em> and a <a href="/url" title="title">link</a>.</p>
```

The input must be UTF-8 with LF line endings. The exit status is 0 on success.

## Library use

```go
package main

import (
	"fmt"

	"example.com/commonmark"
	"example.com/commonmark/ast"
)

func main() {
	// One call:
	fmt.Print(commonmark.ToHTML("# Hello\n\nSome *emphasis*.\n"))

	// Or parse once, inspect the tree, then render:
	doc := commonmark.Parse("- one\n- two\n")
	ast.Walk(doc, func(n *ast.Node, entering bool) ast.WalkStatus {
		if entering && n.Kind == ast.Item {
			fmt.Println("found a list item")
		}
		return ast.Continue
	})
	fmt.Print(commonmark.RenderHTML(doc))
}
```

## Tests

`go test ./...` runs unit tests for each package, the CommonMark spec examples
(`testdata/spec_examples.json`) and golden input/output pairs produced by cmark
(`testdata/golden`).
