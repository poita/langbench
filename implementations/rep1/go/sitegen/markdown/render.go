package markdown

import "strings"

// This file implements the HTML renderer: an iterative enter/exit walk of the
// node tree (inline nesting can be thousands of levels deep).

type renderer struct {
	b       strings.Builder
	imgDeep int // > 0 while inside an image: output plain alt text only
}

func render(doc *node) string {
	r := &renderer{}
	r.walk(doc)
	return r.b.String()
}

func (r *renderer) walk(root *node) {
	n := root
	for {
		r.enter(n)
		if n.first != nil {
			n = n.first
			continue
		}
		for {
			r.exit(n)
			if n == root {
				return
			}
			if n.next != nil {
				n = n.next
				break
			}
			n = n.parent
		}
	}
}

// cr emits a newline unless the output is empty or already ends with one.
func (r *renderer) cr() {
	if l := r.b.Len(); l > 0 && lastByte(&r.b) != '\n' {
		r.b.WriteByte('\n')
	}
}

func lastByte(b *strings.Builder) byte {
	s := b.String()
	return s[len(s)-1]
}

func isTight(n *node) bool {
	if n.parent == nil || n.parent.parent == nil {
		return false
	}
	g := n.parent.parent
	return g.typ == nList && g.list.tight
}

func (r *renderer) enter(n *node) {
	if r.imgDeep > 0 {
		switch n.typ {
		case nText, nCode:
			r.escape(n.literal)
		case nSoftbreak, nLinebreak:
			r.b.WriteByte(' ')
		case nImage:
			r.imgDeep++
		}
		return
	}
	b := &r.b
	switch n.typ {
	case nBlockQuote:
		r.cr()
		b.WriteString("<blockquote>\n")
	case nList:
		r.cr()
		switch {
		case !n.list.ordered:
			b.WriteString("<ul>\n")
		case n.list.start == 1:
			b.WriteString("<ol>\n")
		default:
			b.WriteString("<ol start=\"")
			b.WriteString(itoa(n.list.start))
			b.WriteString("\">\n")
		}
	case nItem:
		r.cr()
		b.WriteString("<li>")
	case nParagraph:
		if !isTight(n) {
			r.cr()
			b.WriteString("<p>")
		}
	case nHeading:
		r.cr()
		b.WriteString("<h")
		b.WriteByte(byte('0' + n.level))
		b.WriteByte('>')
	case nThematicBreak:
		r.cr()
		b.WriteString("<hr />\n")
	case nCodeBlock:
		r.cr()
		if n.info == "" {
			b.WriteString("<pre><code>")
		} else {
			end := 0
			for end < len(n.info) && !isSpace(n.info[end]) {
				end++
			}
			word := n.info[:end]
			b.WriteString("<pre><code class=\"")
			if !strings.HasPrefix(word, "language-") {
				b.WriteString("language-")
			}
			r.escape(word)
			b.WriteString("\">")
		}
		r.escape(n.literal)
		b.WriteString("</code></pre>\n")
	case nText:
		r.escape(n.literal)
	case nSoftbreak:
		b.WriteByte('\n')
	case nLinebreak:
		b.WriteString("<br />\n")
	case nCode:
		b.WriteString("<code>")
		r.escape(n.literal)
		b.WriteString("</code>")
	case nEmph:
		b.WriteString("<em>")
	case nStrong:
		b.WriteString("<strong>")
	case nLink:
		b.WriteString("<a href=\"")
		r.href(n.dest)
		b.WriteByte('"')
		if n.hasTitle {
			b.WriteString(" title=\"")
			r.escape(n.title)
			b.WriteByte('"')
		}
		b.WriteByte('>')
	case nImage:
		b.WriteString("<img src=\"")
		r.href(n.dest)
		b.WriteString("\" alt=\"")
		r.imgDeep++
	}
}

func (r *renderer) exit(n *node) {
	b := &r.b
	if r.imgDeep > 0 {
		if n.typ == nImage {
			r.imgDeep--
			if r.imgDeep == 0 {
				b.WriteByte('"')
				if n.hasTitle {
					b.WriteString(" title=\"")
					r.escape(n.title)
					b.WriteByte('"')
				}
				b.WriteString(" />")
			}
		}
		return
	}
	switch n.typ {
	case nBlockQuote:
		r.cr()
		b.WriteString("</blockquote>\n")
	case nList:
		if n.list.ordered {
			b.WriteString("</ol>\n")
		} else {
			b.WriteString("</ul>\n")
		}
	case nItem:
		b.WriteString("</li>\n")
	case nParagraph:
		if !isTight(n) {
			b.WriteString("</p>\n")
		}
	case nHeading:
		b.WriteString("</h")
		b.WriteByte(byte('0' + n.level))
		b.WriteString(">\n")
	case nEmph:
		b.WriteString("</em>")
	case nStrong:
		b.WriteString("</strong>")
	case nLink:
		b.WriteString("</a>")
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	return string(buf[i:])
}

// escape writes s with & < > " replaced by entities.
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
		r.b.WriteString(s[last:i])
		r.b.WriteString(rep)
		last = i + 1
	}
	r.b.WriteString(s[last:])
}

var hrefSafe = func() (t [256]bool) {
	for _, c := range []byte("-_.~!#$%()*+,/:;=?@") {
		t[c] = true
	}
	for c := 'a'; c <= 'z'; c++ {
		t[c] = true
		t[c-32] = true
	}
	for c := '0'; c <= '9'; c++ {
		t[c] = true
	}
	return
}()

const hexDigits = "0123456789ABCDEF"

// href writes a link destination, percent-encoding unsafe bytes. Dangerous
// schemes produce an empty value.
func (r *renderer) href(dest string) {
	if dangerousURL(dest) {
		return
	}
	last := 0
	for i := 0; i < len(dest); i++ {
		c := dest[i]
		if hrefSafe[c] {
			continue
		}
		r.b.WriteString(dest[last:i])
		last = i + 1
		switch c {
		case '&':
			r.b.WriteString("&amp;")
		case '\'':
			r.b.WriteString("&#x27;")
		default:
			r.b.WriteByte('%')
			r.b.WriteByte(hexDigits[c>>4])
			r.b.WriteByte(hexDigits[c&15])
		}
	}
	r.b.WriteString(dest[last:])
}

func hasPrefixFold(s, prefix string) bool {
	if len(s) < len(prefix) {
		return false
	}
	for i := 0; i < len(prefix); i++ {
		c := s[i]
		if c >= 'A' && c <= 'Z' {
			c += 32
		}
		if c != prefix[i] {
			return false
		}
	}
	return true
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
