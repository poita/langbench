// Package commonmark converts Markdown to HTML following the CommonMark
// specification, producing the same output as the reference
// implementation cmark for the subset described in the README: no HTML
// blocks, raw inline HTML or link reference definitions, and only the
// named character references &amp; &lt; &gt; and &quot;.
//
// The conversion has three stages: a line-oriented block parser builds a
// tree of containers and leaf blocks, the raw text of each paragraph and
// heading is parsed into inlines (with the delimiter-stack emphasis
// algorithm and a bracket stack for links and images), and the result is
// rendered as HTML.
//
// The simplest use is ToHTML:
//
//	html := commonmark.ToHTML([]byte("# Hello *world*"))
//
// Parse gives access to the parsed document when it should be rendered
// more than once or written to an io.Writer.
package commonmark

import "io"

// Document is a parsed Markdown document.
type Document struct {
	root *block
	size int
}

// Parse parses the block structure of src. Inline content is parsed
// lazily while the document is rendered.
func Parse(src []byte) *Document {
	return &Document{root: parseBlocks(src), size: len(src)}
}

// HTML renders the document as HTML.
func (d *Document) HTML() []byte {
	return renderHTML(d.root, d.size)
}

// WriteTo renders the document and writes the HTML to w with a single
// Write call. It implements io.WriterTo.
func (d *Document) WriteTo(w io.Writer) (int64, error) {
	out := d.HTML()
	n, err := w.Write(out)
	return int64(n), err
}

// ToHTML converts Markdown source to HTML.
func ToHTML(src []byte) []byte {
	return Parse(src).HTML()
}

// ToHTMLString converts a Markdown string to an HTML string.
func ToHTMLString(src string) string {
	return string(ToHTML([]byte(src)))
}
