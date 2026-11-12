package markdown

import (
	"strconv"
	"strings"
)

// renderer writes the HTML for a finished tree.
type renderer struct {
	buf []byte
}

func (r *renderer) cr() {
	if n := len(r.buf); n > 0 && r.buf[n-1] != '\n' {
		r.buf = append(r.buf, '\n')
	}
}

func (r *renderer) str(s string) { r.buf = append(r.buf, s...) }

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

const hexDigits = "0123456789ABCDEF"

func hrefSafe(c byte) bool {
	switch {
	case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		return true
	}
	return strings.IndexByte("-_.~!#$%()*+,/:;=?@", c) >= 0
}

func hasPrefixFold(s, prefix string) bool {
	return len(s) >= len(prefix) && strings.EqualFold(s[:len(prefix)], prefix)
}

func dangerousURL(u string) bool {
	for _, p := range []string{"javascript:", "vbscript:", "file:"} {
		if hasPrefixFold(u, p) {
			return true
		}
	}
	if hasPrefixFold(u, "data:") {
		for _, p := range []string{"data:image/png", "data:image/gif", "data:image/jpeg", "data:image/webp"} {
			if hasPrefixFold(u, p) {
				return false
			}
		}
		return true
	}
	return false
}

func (r *renderer) href(u string) {
	if dangerousURL(u) {
		return
	}
	for i := 0; i < len(u); i++ {
		c := u[i]
		switch {
		case c == '&':
			r.str("&amp;")
		case c == '\'':
			r.str("&#x27;")
		case hrefSafe(c):
			r.buf = append(r.buf, c)
		default:
			r.buf = append(r.buf, '%', hexDigits[c>>4], hexDigits[c&15])
		}
	}
}

func (r *renderer) children(n *node) {
	for c := n.first; c != nil; c = c.next {
		r.node(c)
	}
}

func (r *renderer) node(n *node) {
	switch n.kind {
	case kDocument:
		r.children(n)
	case kBlockQuote:
		r.cr()
		r.str("<blockquote>\n")
		r.children(n)
		r.cr()
		r.str("</blockquote>\n")
	case kList:
		r.cr()
		switch {
		case !n.ordered:
			r.str("<ul>\n")
		case n.start == 1:
			r.str("<ol>\n")
		default:
			r.str("<ol start=\"" + strconv.Itoa(n.start) + "\">\n")
		}
		r.children(n)
		if n.ordered {
			r.str("</ol>\n")
		} else {
			r.str("</ul>\n")
		}
	case kItem:
		r.cr()
		r.str("<li>")
		r.children(n)
		r.str("</li>\n")
	case kParagraph:
		if n.parent != nil && n.parent.parent != nil && n.parent.parent.kind == kList && n.parent.parent.tight {
			r.children(n)
		} else {
			r.cr()
			r.str("<p>")
			r.children(n)
			r.str("</p>\n")
		}
	case kHeading:
		r.cr()
		tag := "h" + strconv.Itoa(n.level)
		r.str("<" + tag + ">")
		r.children(n)
		r.str("</" + tag + ">\n")
	case kThematicBreak:
		r.cr()
		r.str("<hr />\n")
	case kCodeBlock:
		r.cr()
		if n.info == "" {
			r.str("<pre><code>")
		} else {
			lang := n.info
			if i := strings.IndexFunc(lang, func(c rune) bool { return c < 128 && isWhitespace(byte(c)) }); i >= 0 {
				lang = lang[:i]
			}
			r.str("<pre><code class=\"")
			if !strings.HasPrefix(lang, "language-") {
				r.str("language-")
			}
			r.escape(lang)
			r.str("\">")
		}
		r.escape(n.lit)
		r.str("</code></pre>\n")
	case kText:
		r.escape(n.lit)
	case kSoftBreak:
		r.str("\n")
	case kLineBreak:
		r.str("<br />\n")
	case kCode:
		r.str("<code>")
		r.escape(n.lit)
		r.str("</code>")
	case kEmph:
		r.str("<em>")
		r.children(n)
		r.str("</em>")
	case kStrong:
		r.str("<strong>")
		r.children(n)
		r.str("</strong>")
	case kLink:
		r.str("<a href=\"")
		r.href(n.dest)
		r.str("\"")
		if n.hasTitle {
			r.str(" title=\"")
			r.escape(n.title)
			r.str("\"")
		}
		r.str(">")
		r.children(n)
		r.str("</a>")
	case kImage:
		r.str("<img src=\"")
		r.href(n.dest)
		r.str("\" alt=\"")
		r.altText(n)
		r.str("\"")
		if n.hasTitle {
			r.str(" title=\"")
			r.escape(n.title)
			r.str("\"")
		}
		r.str(" />")
	}
}

// altText writes the plain text content of an image's descendants.
func (r *renderer) altText(n *node) {
	for c := n.first; c != nil; c = c.next {
		switch c.kind {
		case kText, kCode:
			r.escape(c.lit)
		case kSoftBreak, kLineBreak:
			r.str(" ")
		default:
			r.altText(c)
		}
	}
}
