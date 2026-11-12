package inline

import (
	"strings"

	"example.com/commonmark/ast"
	"example.com/commonmark/internal/scan"
)

// autolink handles a '<' at the current position: it emits an autolink if
// one starts here, else the '<' as text.
func (p *parser) autolink() {
	rest := p.s[p.pos+1:]
	if n, email := matchAutolink(rest); n > 0 {
		body := rest[:n-1]
		dest := scan.DecodeEntities(body)
		l := ast.New(ast.Link)
		if email {
			l.Dest = "mailto:" + dest
		} else {
			l.Dest = dest
		}
		p.parent.AppendChild(l)
		l.AppendChild(&ast.Node{Kind: ast.Text, Literal: dest})
		p.pos += 1 + n
		return
	}
	p.pos++
	p.text("<")
}

// matchAutolink matches a URI or email autolink body followed by '>' at the
// start of s (the text after the '<'). It returns the number of bytes
// consumed, including the '>', or 0.
func matchAutolink(s string) (n int, email bool) {
	if n := matchURI(s); n > 0 {
		return n, false
	}
	if n := matchEmail(s); n > 0 {
		return n, true
	}
	return 0, false
}

// matchURI matches [A-Za-z][A-Za-z0-9.+-]{1,31}:[^\x00-\x20<>]*>
func matchURI(s string) int {
	if len(s) == 0 || !scan.IsAlpha(s[0]) {
		return 0
	}
	i := 1
	for i < len(s) && i < 33 && (scan.IsAlnum(s[i]) || s[i] == '.' || s[i] == '+' || s[i] == '-') {
		i++
	}
	if i < 2 || i >= len(s) || s[i] != ':' {
		return 0
	}
	for i++; i < len(s); i++ {
		c := s[i]
		if c == '>' {
			return i + 1
		}
		if c <= ' ' || c == '<' {
			return 0
		}
	}
	return 0
}

const emailLocalChars = ".!#$%&'*+/=?^_`{|}~-"

// matchEmail matches the email autolink grammar of the CommonMark spec.
func matchEmail(s string) int {
	i := 0
	for i < len(s) && (scan.IsAlnum(s[i]) || strings.IndexByte(emailLocalChars, s[i]) >= 0) {
		i++
	}
	if i == 0 || i >= len(s) || s[i] != '@' {
		return 0
	}
	i++
	for {
		start := i
		for i < len(s) && (scan.IsAlnum(s[i]) || s[i] == '-') {
			i++
		}
		if i == start || i-start > 63 || s[start] == '-' || s[i-1] == '-' || i >= len(s) {
			return 0
		}
		switch s[i] {
		case '>':
			return i + 1
		case '.':
			i++
		default:
			return 0
		}
	}
}
