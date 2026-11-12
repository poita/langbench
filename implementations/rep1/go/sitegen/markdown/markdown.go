// Package markdown converts a documented subset of CommonMark to HTML.
//
// The converter follows the structure of the reference implementation cmark:
// a line-driven block parser builds a tree of containers and leaf blocks, the
// raw text of paragraphs and headings is then parsed into inlines with a
// delimiter stack and a bracket stack, and a single walk renders the tree.
//
// Supported constructs: thematic breaks, ATX and setext headings, indented
// and fenced code blocks, paragraphs, block quotes, lists, backslash escapes,
// entity references (numeric ones and &amp; &lt; &gt; &quot;), code spans,
// emphasis and strong emphasis, inline links and images, autolinks, and hard
// and soft line breaks. HTML blocks, raw inline HTML, link reference
// definitions and extensions (tables, strikethrough, ...) are not supported:
// their syntax is treated as ordinary text.
//
// Input is expected to be UTF-8 with LF line endings. Output is never
// sanitised beyond the escaping CommonMark prescribes.
package markdown

// ToHTML converts the Markdown document src to HTML. The result ends with a
// newline unless it is empty.
func ToHTML(src string) string {
	doc := parseBlocks(src)
	parseInlineContent(doc)
	r := &renderer{buf: make([]byte, 0, len(src)+len(src)/2+16)}
	r.node(doc)
	return string(r.buf)
}

// parseInlineContent walks the block tree and parses the raw content of every
// paragraph and heading into inline nodes.
func parseInlineContent(n *node) {
	for c := n.first; c != nil; c = c.next {
		switch c.kind {
		case kParagraph, kHeading:
			parseInlines(c, string(c.content))
			c.content = nil
		case kBlockQuote, kList, kItem:
			parseInlineContent(c)
		}
	}
}
