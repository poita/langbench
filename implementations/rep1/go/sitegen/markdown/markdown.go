// Package markdown converts the CommonMark subset used by sitegen to HTML.
//
// The converter follows the architecture of the cmark reference
// implementation: a line-driven block parser builds a tree of containers and
// leaves, the raw text of paragraphs and headings is then parsed into inline
// nodes with a delimiter stack and a bracket stack, and an iterative walk of
// the tree renders HTML.
//
// Supported: thematic breaks, ATX and setext headings, indented and fenced
// code blocks, paragraphs, block quotes, lists, backslash escapes, entity
// references (&amp; &lt; &gt; &quot; and numeric), code spans, emphasis,
// inline links and images, autolinks, hard and soft line breaks.
//
// Not supported (the input is assumed never to contain them): raw HTML,
// link reference definitions and extensions such as tables.
package markdown

// ToHTML converts the Markdown document src to HTML. The result ends with a
// newline unless the document produces no output, in which case it is empty.
func ToHTML(src string) string {
	p := newParser(src)
	doc := p.parse()
	parseBlockInlines(doc)
	return render(doc)
}
