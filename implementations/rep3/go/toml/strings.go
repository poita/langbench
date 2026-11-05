package toml

import "unicode/utf8"

// strPlain marks the bytes that may appear unescaped in any string form:
// tab, 0x20-0x7E and everything from 0x80 up. (Quote and backslash are
// handled explicitly by the scanners.)
var strPlain = func() (t [256]bool) {
	t['\t'] = true
	for c := 0x20; c < 0x7f; c++ {
		t[c] = true
	}
	for c := 0x80; c < 0x100; c++ {
		t[c] = true
	}
	return
}()

// basicString parses a single-line basic string; the cursor is on the opening quote.
func (p *parser) basicString() string {
	p.pos++
	start := p.pos
	var buf []byte // allocated at the first escape
	for {
		run := p.pos
		for p.pos < len(p.src) && strPlain[p.src[p.pos]] && p.src[p.pos] != '"' && p.src[p.pos] != '\\' {
			p.pos++
		}
		if buf != nil {
			buf = append(buf, p.src[run:p.pos]...)
		}
		if p.pos >= len(p.src) {
			p.fail("unterminated string")
		}
		switch p.src[p.pos] {
		case '"':
			s := p.src[start:p.pos]
			if buf != nil {
				s = buf
			}
			p.pos++
			return string(s)
		case '\\':
			if buf == nil {
				buf = append(make([]byte, 0, p.pos-start+16), p.src[start:p.pos]...)
			}
			p.pos++
			buf = p.escape(buf)
		default:
			p.fail("invalid character in string")
		}
	}
}

// escape decodes the escape sequence whose backslash was just consumed.
func (p *parser) escape(buf []byte) []byte {
	if p.pos >= len(p.src) {
		p.fail("unterminated escape")
	}
	c := p.src[p.pos]
	p.pos++
	switch c {
	case 'b':
		return append(buf, '\b')
	case 't':
		return append(buf, '\t')
	case 'n':
		return append(buf, '\n')
	case 'f':
		return append(buf, '\f')
	case 'r':
		return append(buf, '\r')
	case '"':
		return append(buf, '"')
	case '\\':
		return append(buf, '\\')
	case 'u':
		return p.unicodeEscape(buf, 4)
	case 'U':
		return p.unicodeEscape(buf, 8)
	}
	p.failAt(p.pos-1, "invalid escape sequence")
	return nil
}

func (p *parser) unicodeEscape(buf []byte, digits int) []byte {
	if len(p.src)-p.pos < digits {
		p.fail("truncated unicode escape")
	}
	var v uint32
	for i := 0; i < digits; i++ {
		h, ok := hexVal(p.src[p.pos+i])
		if !ok {
			p.failAt(p.pos+i, "invalid hex digit in unicode escape")
		}
		v = v<<4 | uint32(h)
	}
	if v > utf8.MaxRune || (v >= 0xD800 && v <= 0xDFFF) {
		p.fail("escape is not a unicode scalar value")
	}
	p.pos += digits
	return utf8.AppendRune(buf, rune(v))
}

func hexVal(c byte) (int, bool) {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0'), true
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10, true
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10, true
	}
	return 0, false
}

// literalString parses a single-line literal string; the cursor is on the opening quote.
func (p *parser) literalString() string {
	p.pos++
	start := p.pos
	for p.pos < len(p.src) && strPlain[p.src[p.pos]] && p.src[p.pos] != '\'' {
		p.pos++
	}
	if p.pos >= len(p.src) {
		p.fail("unterminated literal string")
	}
	if p.src[p.pos] != '\'' {
		p.fail("invalid character in literal string")
	}
	s := string(p.src[start:p.pos])
	p.pos++
	return s
}

// skipOpeningNewline discards a newline immediately after a multi-line opener.
func (p *parser) skipOpeningNewline() {
	if p.pos < len(p.src) && p.src[p.pos] == '\n' {
		p.pos++
	} else if p.pos+1 < len(p.src) && p.src[p.pos] == '\r' && p.src[p.pos+1] == '\n' {
		p.pos += 2
	}
}

// multiBasicString parses a """ string; the cursor is on the opening delimiter.
func (p *parser) multiBasicString() string {
	p.pos += 3
	p.skipOpeningNewline()
	buf := make([]byte, 0, 32)
	for {
		run := p.pos
		for p.pos < len(p.src) && strPlain[p.src[p.pos]] && p.src[p.pos] != '"' && p.src[p.pos] != '\\' {
			p.pos++
		}
		buf = append(buf, p.src[run:p.pos]...)
		if p.pos >= len(p.src) {
			p.fail("unterminated multi-line string")
		}
		switch c := p.src[p.pos]; c {
		case '"':
			n := p.quoteRun('"')
			if n < 3 {
				buf = appendN(buf, '"', n)
				continue
			}
			if n > 5 {
				p.fail("too many quotes in multi-line string")
			}
			buf = appendN(buf, '"', n-3)
			return string(buf)
		case '\\':
			p.pos++
			if p.lineEndingBackslash() {
				continue
			}
			buf = p.escape(buf)
		case '\n':
			buf = append(buf, '\n')
			p.pos++
		case '\r': // always CRLF
			buf = append(buf, '\n')
			p.pos += 2
		default:
			p.fail("invalid character in string")
		}
	}
}

// lineEndingBackslash handles a backslash (already consumed) followed by
// optional whitespace and a newline: it then skips all following whitespace
// and newlines. It reports whether it applied; if not, the cursor is unchanged.
func (p *parser) lineEndingBackslash() bool {
	i := p.pos
	for i < len(p.src) && (p.src[i] == ' ' || p.src[i] == '\t') {
		i++
	}
	if i >= len(p.src) || (p.src[i] != '\n' && p.src[i] != '\r') {
		return false
	}
	for i < len(p.src) {
		switch p.src[i] {
		case ' ', '\t', '\n', '\r':
			i++
		default:
			p.pos = i
			return true
		}
	}
	p.pos = i
	return true
}

// quoteRun counts consecutive q bytes at the cursor and advances past them.
func (p *parser) quoteRun(q byte) int {
	n := 0
	for p.pos < len(p.src) && p.src[p.pos] == q {
		p.pos++
		n++
	}
	return n
}

func appendN(buf []byte, c byte, n int) []byte {
	for ; n > 0; n-- {
		buf = append(buf, c)
	}
	return buf
}

// multiLiteralString parses a ”' string; the cursor is on the opening delimiter.
func (p *parser) multiLiteralString() string {
	p.pos += 3
	p.skipOpeningNewline()
	buf := make([]byte, 0, 32)
	for {
		run := p.pos
		for p.pos < len(p.src) && strPlain[p.src[p.pos]] && p.src[p.pos] != '\'' {
			p.pos++
		}
		buf = append(buf, p.src[run:p.pos]...)
		if p.pos >= len(p.src) {
			p.fail("unterminated multi-line literal string")
		}
		switch p.src[p.pos] {
		case '\'':
			n := p.quoteRun('\'')
			if n < 3 {
				buf = appendN(buf, '\'', n)
				continue
			}
			if n > 5 {
				p.fail("too many quotes in multi-line literal string")
			}
			buf = appendN(buf, '\'', n-3)
			return string(buf)
		case '\n':
			buf = append(buf, '\n')
			p.pos++
		case '\r':
			buf = append(buf, '\n')
			p.pos += 2
		default:
			p.fail("invalid character in literal string")
		}
	}
}
