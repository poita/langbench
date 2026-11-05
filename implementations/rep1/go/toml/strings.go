package toml

import "unicode/utf8"

// forbidden reports whether c may not appear unescaped in a string or
// comment: C0 controls other than tab, and DEL.
func forbidden(c byte) bool { return (c < 0x20 && c != '\t') || c == 0x7f }

// basicString parses a single-line "basic string"; the cursor is on the
// opening quote.
func (p *parser) basicString() string {
	src := p.src
	p.pos++
	start := p.pos
	var buf []byte
	escaped := false
	for {
		if p.pos >= len(src) {
			p.fail("unterminated string")
		}
		switch c := src[p.pos]; {
		case c == '"':
			var s string
			if escaped {
				buf = append(buf, src[start:p.pos]...)
				p.scratch = buf[:0]
				s = string(buf)
			} else {
				s = string(src[start:p.pos])
			}
			p.pos++
			return s
		case c == '\\':
			if !escaped {
				escaped = true
				buf = p.scratch[:0]
			}
			buf = append(buf, src[start:p.pos]...)
			p.pos++
			buf = p.escape(buf)
			start = p.pos
		case forbidden(c):
			p.fail("control character in string")
		default:
			p.pos++
		}
	}
}

// literalString parses a single-line 'literal string'; the cursor is on the
// opening quote.
func (p *parser) literalString() string {
	src := p.src
	p.pos++
	start := p.pos
	for {
		if p.pos >= len(src) {
			p.fail("unterminated string")
		}
		c := src[p.pos]
		if c == '\'' {
			s := string(src[start:p.pos])
			p.pos++
			return s
		}
		if forbidden(c) {
			p.fail("control character in string")
		}
		p.pos++
	}
}

// escape decodes the escape sequence after a backslash (cursor just past the
// backslash), appends the result to buf and advances the cursor.
func (p *parser) escape(buf []byte) []byte {
	if p.eof() {
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
	p.pos--
	p.fail("invalid escape sequence")
	return buf
}

func (p *parser) unicodeEscape(buf []byte, digits int) []byte {
	if p.pos+digits > len(p.src) {
		p.fail("truncated unicode escape")
	}
	var r uint32
	for i := 0; i < digits; i++ {
		d, ok := hexVal(p.src[p.pos+i])
		if !ok {
			p.pos += i
			p.fail("invalid hex digit in unicode escape")
		}
		r = r<<4 | uint32(d)
	}
	if r > utf8.MaxRune || (r >= 0xD800 && r <= 0xDFFF) {
		p.fail("escape is not a unicode scalar value")
	}
	p.pos += digits
	return utf8.AppendRune(buf, rune(r))
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

// skipOpeningNewline discards a newline directly after a multi-line opening
// delimiter.
func (p *parser) skipOpeningNewline() {
	if p.pos < len(p.src) {
		if p.src[p.pos] == '\n' {
			p.pos++
		} else if p.src[p.pos] == '\r' {
			p.pos += 2
		}
	}
}

// quoteRun returns the length of the run of q bytes at the cursor.
func (p *parser) quoteRun(q byte) int {
	n := 0
	for p.pos+n < len(p.src) && p.src[p.pos+n] == q {
		n++
	}
	return n
}

// multilineBasicString parses a """ string; the cursor is on the opening
// delimiter.
func (p *parser) multilineBasicString() string {
	src := p.src
	p.pos += 3
	p.skipOpeningNewline()
	buf := p.scratch[:0]
	for {
		if p.pos >= len(src) {
			p.fail("unterminated multi-line string")
		}
		c := src[p.pos]
		switch {
		case c == '"':
			n := p.quoteRun('"')
			if n < 3 {
				buf = append(buf, src[p.pos:p.pos+n]...)
				p.pos += n
				continue
			}
			if n > 5 {
				p.fail("too many quotes in multi-line string")
			}
			buf = append(buf, src[p.pos:p.pos+n-3]...)
			p.pos += n
			p.scratch = buf[:0]
			return string(buf)
		case c == '\\':
			p.pos++
			// Line-ending backslash: optional whitespace, then a newline.
			j := p.pos
			for j < len(src) && (src[j] == ' ' || src[j] == '\t') {
				j++
			}
			if j < len(src) && (src[j] == '\n' || src[j] == '\r') {
				for j < len(src) {
					switch src[j] {
					case ' ', '\t', '\n':
						j++
						continue
					case '\r':
						j += 2
						continue
					}
					break
				}
				p.pos = j
				continue
			}
			buf = p.escape(buf)
		case c == '\r':
			buf = append(buf, '\n')
			p.pos += 2
		case c == '\n':
			buf = append(buf, '\n')
			p.pos++
		case forbidden(c):
			p.fail("control character in string")
		default:
			buf = append(buf, c)
			p.pos++
		}
	}
}

// multilineLiteralString parses a ”' string; the cursor is on the opening
// delimiter.
func (p *parser) multilineLiteralString() string {
	src := p.src
	p.pos += 3
	p.skipOpeningNewline()
	buf := p.scratch[:0]
	for {
		if p.pos >= len(src) {
			p.fail("unterminated multi-line string")
		}
		c := src[p.pos]
		switch {
		case c == '\'':
			n := p.quoteRun('\'')
			if n < 3 {
				buf = append(buf, src[p.pos:p.pos+n]...)
				p.pos += n
				continue
			}
			if n > 5 {
				p.fail("too many quotes in multi-line string")
			}
			buf = append(buf, src[p.pos:p.pos+n-3]...)
			p.pos += n
			p.scratch = buf[:0]
			return string(buf)
		case c == '\r':
			buf = append(buf, '\n')
			p.pos += 2
		case c == '\n':
			buf = append(buf, '\n')
			p.pos++
		case forbidden(c):
			p.fail("control character in string")
		default:
			buf = append(buf, c)
			p.pos++
		}
	}
}
