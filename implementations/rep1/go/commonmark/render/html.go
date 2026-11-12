// Package render writes a document tree as HTML in the style of cmark.
package render

import (
	"strconv"
	"strings"

	"example.com/commonmark/ast"
)

// HTML renders the tree rooted at doc and returns the HTML. Deeply nested
// trees are fine: the traversal does not recurse.
func HTML(doc *ast.Node) string {
	r := &renderer{}
	r.buf = make([]byte, 0, 1024)
	ast.Walk(doc, r.visit)
	return string(r.buf)
}

type renderer struct {
	buf []byte
	alt *ast.Node // outermost image whose alt text is being written
}

// cr starts a new line unless the output is empty or already at line start.
func (r *renderer) cr() {
	if n := len(r.buf); n > 0 && r.buf[n-1] != '\n' {
		r.buf = append(r.buf, '\n')
	}
}

func (r *renderer) str(s string) { r.buf = append(r.buf, s...) }

// escape appends s with & < > " replaced by entities.
func (r *renderer) escape(s string) {
	last := 0
	for i := 0; i < len(s); i++ {
		var rep string
		switch s[i] {
		case '&':
			rep = "&amp;"
		case '<':
			rep = "&lt;"
		case '>':
			rep = "&gt;"
		case '"':
			rep = "&quot;"
		default:
			continue
		}
		r.buf = append(r.buf, s[last:i]...)
		r.buf = append(r.buf, rep...)
		last = i + 1
	}
	r.buf = append(r.buf, s[last:]...)
}

func hasPrefixFold(s, prefix string) bool {
	return len(s) >= len(prefix) && strings.EqualFold(s[:len(prefix)], prefix)
}

func safeURL(u string) bool {
	for _, p := range [...]string{"javascript:", "vbscript:", "file:", "data:"} {
		if hasPrefixFold(u, p) {
			for _, ok := range [...]string{"data:image/png", "data:image/gif", "data:image/jpeg", "data:image/webp"} {
				if hasPrefixFold(u, ok) {
					return true
				}
			}
			return false
		}
	}
	return true
}

const hexDigits = "0123456789ABCDEF"

// href appends the URL-encoded form of a destination.
func (r *renderer) href(u string) {
	if !safeURL(u) {
		return
	}
	for i := 0; i < len(u); i++ {
		c := u[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9',
			strings.IndexByte("-_.~!#$%()*+,/:;=?@", c) >= 0:
			r.buf = append(r.buf, c)
		case c == '&':
			r.str("&amp;")
		case c == '\'':
			r.str("&#x27;")
		default:
			r.buf = append(r.buf, '%', hexDigits[c>>4], hexDigits[c&15])
		}
	}
}

func (r *renderer) title(n *ast.Node) {
	if n.HasTitle {
		r.str(` title="`)
		r.escape(n.Title)
		r.str(`"`)
	}
}

// visit renders one traversal event.
func (r *renderer) visit(n *ast.Node, entering bool) ast.WalkStatus {
	if r.alt != nil {
		r.visitAlt(n, entering)
		return ast.Continue
	}
	switch n.Kind {
	case ast.Document:
	case ast.BlockQuote:
		if entering {
			r.cr()
			r.str("<blockquote>\n")
		} else {
			r.cr()
			r.str("</blockquote>\n")
		}
	case ast.List:
		if entering {
			r.cr()
			switch {
			case n.List.Type == ast.Bullet:
				r.str("<ul>\n")
			case n.List.Start == 1:
				r.str("<ol>\n")
			default:
				r.str("<ol start=\"" + strconv.Itoa(n.List.Start) + "\">\n")
			}
		} else if n.List.Type == ast.Bullet {
			r.str("</ul>\n")
		} else {
			r.str("</ol>\n")
		}
	case ast.Item:
		if entering {
			r.cr()
			r.str("<li>")
		} else {
			r.str("</li>\n")
		}
	case ast.Paragraph:
		if p := n.Parent; p.Kind == ast.Item && p.Parent.List.Tight {
			break
		}
		if entering {
			r.cr()
			r.str("<p>")
		} else {
			r.str("</p>\n")
		}
	case ast.Heading:
		tag := "h" + strconv.Itoa(n.Level)
		if entering {
			r.cr()
			r.str("<" + tag + ">")
		} else {
			r.str("</" + tag + ">\n")
		}
	case ast.ThematicBreak:
		if entering {
			r.cr()
			r.str("<hr />\n")
		}
	case ast.CodeBlock:
		if !entering {
			break
		}
		r.cr()
		r.str("<pre><code")
		if n.Info != "" {
			lang := n.Info
			if i := strings.IndexFunc(lang, func(c rune) bool { return c == ' ' || (c >= '\t' && c <= '\r') }); i >= 0 {
				lang = lang[:i]
			}
			r.str(` class="`)
			if !strings.HasPrefix(lang, "language-") {
				r.str("language-")
			}
			r.escape(lang)
			r.str(`"`)
		}
		r.str(">")
		r.escape(n.Literal)
		r.str("</code></pre>\n")
	case ast.Text:
		if entering {
			r.escape(n.Literal)
		}
	case ast.Softbreak:
		if entering {
			r.str("\n")
		}
	case ast.Linebreak:
		if entering {
			r.str("<br />\n")
		}
	case ast.Code:
		if entering {
			r.str("<code>")
			r.escape(n.Literal)
			r.str("</code>")
		}
	case ast.Emph:
		if entering {
			r.str("<em>")
		} else {
			r.str("</em>")
		}
	case ast.Strong:
		if entering {
			r.str("<strong>")
		} else {
			r.str("</strong>")
		}
	case ast.Link:
		if entering {
			r.str(`<a href="`)
			r.href(n.Dest)
			r.str(`"`)
			r.title(n)
			r.str(">")
		} else {
			r.str("</a>")
		}
	case ast.Image:
		if entering {
			r.str(`<img src="`)
			r.href(n.Dest)
			r.str(`" alt="`)
			r.alt = n
		}
	}
	return ast.Continue
}

// visitAlt renders the plain-text alternative of the image r.alt.
func (r *renderer) visitAlt(n *ast.Node, entering bool) {
	switch n.Kind {
	case ast.Text, ast.Code:
		if entering {
			r.escape(n.Literal)
		}
	case ast.Softbreak, ast.Linebreak:
		if entering {
			r.str(" ")
		}
	}
	if n == r.alt && !entering {
		r.str(`"`)
		r.title(n)
		r.str(" />")
		r.alt = nil
	}
}
