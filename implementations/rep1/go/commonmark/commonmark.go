// Package commonmark converts the CommonMark subset described in SPEC.md to
// HTML, producing the same output as the reference implementation cmark.
//
// Conversion has two phases, as in the CommonMark specification: [Parse]
// builds a tree of blocks line by line and then parses the inline content of
// paragraphs and headings; [RenderHTML] walks the tree and writes HTML. The
// common case is a single call to [ToHTML].
//
// The tree types live in package ast, the block phase in package block, the
// inline phase in package inline and the HTML writer in package render; they
// can be used directly.
//
// Not supported, because the subset excludes them: HTML blocks, raw inline
// HTML, link reference definitions (and so reference links), HTML named
// entities other than &amp; &lt; &gt; &quot;, and all extensions.
package commonmark

import (
	"example.com/commonmark/ast"
	"example.com/commonmark/block"
	"example.com/commonmark/inline"
	"example.com/commonmark/render"
)

// Parse parses the Markdown document src, with LF line endings, into a
// document tree whose paragraphs and headings contain inline nodes.
func Parse(src string) *ast.Node {
	doc := block.Parse(src)
	inline.ParseAll(doc)
	return doc
}

// RenderHTML renders a tree returned by Parse as HTML.
func RenderHTML(doc *ast.Node) string { return render.HTML(doc) }

// ToHTML converts a Markdown document to HTML.
func ToHTML(src string) string { return RenderHTML(Parse(src)) }
