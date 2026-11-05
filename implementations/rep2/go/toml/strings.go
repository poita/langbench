package toml

import "unicode/utf8"

func isBareKeyByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-'
}

// parseKey parses a (possibly dotted) key, skipping whitespace around it and
// around each dot. The cursor is left on the first byte after the key.
func (p *parser) parseKey() []string {
	var keys []string
	for {
		p.skipWS()
		keys = append(keys, p.parseSimpleKey())
		p.skipWS()
		if p.pos < len(p.src) && p.src[p.pos] == '.' {
			p.pos++
			continue
		}
		return keys
	}
}

func (p *parser) parseSimpleKey() string {
	if p.eof() {
		p.fail("expected a key")
	}
	switch c := p.src[p.pos]; {
	case c == '"':
		return p.parseBasic()
	case c == '\'':
		return p.parseLiteral()
	case isBareKeyByte(c):
		start := p.pos
		for p.pos < len(p.src) && isBareKeyByte(p.src[p.pos]) {
			p.pos++
		}
		return string(p.src[start:p.pos])
	}
	p.fail("invalid key")
	return ""
}

// plainBasic reports whether c may appear unescaped (and is not a delimiter
// that needs attention) in a basic string.
func stopsBasic(c byte) bool {
	return c == '"' || c == '\\' || (c < 0x20 && c != '\t') || c == 0x7f
}

// parseBasic parses a single-line basic string; the cursor is on the opening quote.
func (p *parser) parseBasic() string {
	src := p.src
	p.pos++
	runStart := p.pos
	var buf []byte
	escaped := false
	for {
		i := p.pos
		for i < len(src) && !stopsBasic(src[i]) {
			i++
		}
		if i >= len(src) {
			p.pos = i
			p.fail("unterminated string")
		}
		switch src[i] {
		case '"':
			p.pos = i + 1
			if !escaped {
				return string(src[runStart:i])
			}
			return string(append(buf, src[runStart:i]...))
		case '\\':
			buf = append(buf, src[runStart:i]...)
			escaped = true
			p.pos = i + 1
			buf = p.parseEscape(buf)
			runStart = p.pos
		default:
			p.failAt(i, "invalid character in string")
		}
	}
}

// parseEscape decodes the escape sequence whose backslash was just consumed
// and appends the result to buf.
func (p *parser) parseEscape(buf []byte) []byte {
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
		return p.appendHexEscape(buf, 4)
	case 'U':
		return p.appendHexEscape(buf, 8)
	}
	p.failAt(p.pos-1, "invalid escape sequence")
	return nil
}

func (p *parser) appendHexEscape(buf []byte, n int) []byte {
	if len(p.src)-p.pos < n {
		p.fail("truncated unicode escape")
	}
	var r uint32
	for i := 0; i < n; i++ {
		c := p.src[p.pos+i]
		var d byte
		switch {
		case c >= '0' && c <= '9':
			d = c - '0'
		case c >= 'a' && c <= 'f':
			d = c - 'a' + 10
		case c >= 'A' && c <= 'F':
			d = c - 'A' + 10
		default:
			p.failAt(p.pos+i, "invalid hex digit in unicode escape")
		}
		r = r<<4 | uint32(d)
	}
	if r > utf8.MaxRune || (r >= 0xD800 && r <= 0xDFFF) {
		p.fail("escape is not a unicode scalar value")
	}
	p.pos += n
	return utf8.AppendRune(buf, rune(r))
}

// parseLiteral parses a single-line literal string; the cursor is on the opening quote.
func (p *parser) parseLiteral() string {
	src := p.src
	p.pos++
	start := p.pos
	for i := start; i < len(src); i++ {
		c := src[i]
		if c == '\'' {
			p.pos = i + 1
			return string(src[start:i])
		}
		if (c < 0x20 && c != '\t') || c == 0x7f {
			p.failAt(i, "invalid character in literal string")
		}
	}
	p.pos = len(src)
	p.fail("unterminated literal string")
	return ""
}

// skipFirstNewline discards a newline directly after an opening delimiter.
func (p *parser) skipFirstNewline() {
	if p.pos < len(p.src) {
		if p.src[p.pos] == '\n' {
			p.pos++
		} else if p.src[p.pos] == '\r' {
			p.pos += 2
		}
	}
}

// parseMLBasic parses a multi-line basic string; the cursor is on the opening """.
func (p *parser) parseMLBasic() string {
	src := p.src
	p.pos += 3
	p.skipFirstNewline()
	var buf []byte
	for {
		i := p.pos
		for i < len(src) {
			c := src[i]
			if c == '"' || c == '\\' || c == '\r' || (c < 0x20 && c != '\t' && c != '\n') || c == 0x7f {
				break
			}
			i++
		}
		buf = append(buf, src[p.pos:i]...)
		p.pos = i
		if i >= len(src) {
			p.fail("unterminated multi-line string")
		}
		switch src[i] {
		case '"':
			j := i
			for j < len(src) && src[j] == '"' {
				j++
			}
			n := j - i
			p.pos = j
			if n < 3 {
				for ; n > 0; n-- {
					buf = append(buf, '"')
				}
				continue
			}
			if n > 5 {
				p.failAt(i, "too many quotes in multi-line string")
			}
			for ; n > 3; n-- {
				buf = append(buf, '"')
			}
			return string(buf)
		case '\r':
			buf = append(buf, '\n')
			p.pos += 2
		case '\\':
			p.pos++
			if p.eof() {
				p.fail("unterminated escape")
			}
			if c := src[p.pos]; c == ' ' || c == '\t' || c == '\n' || c == '\r' {
				p.lineEndingBackslash()
			} else {
				buf = p.parseEscape(buf)
			}
		default:
			p.failAt(i, "invalid character in multi-line string")
		}
	}
}

// lineEndingBackslash handles "\" + optional whitespace + newline, then skips
// all following whitespace and newlines. The cursor is just after the backslash.
func (p *parser) lineEndingBackslash() {
	src := p.src
	j := p.pos
	for j < len(src) && (src[j] == ' ' || src[j] == '\t') {
		j++
	}
	if j >= len(src) || (src[j] != '\n' && src[j] != '\r') {
		p.failAt(j, "invalid escape sequence")
	}
	for j < len(src) && (src[j] == ' ' || src[j] == '\t' || src[j] == '\n' || src[j] == '\r') {
		j++
	}
	p.pos = j
}

// parseMLLiteral parses a multi-line literal string; the cursor is on the opening ”'.
func (p *parser) parseMLLiteral() string {
	src := p.src
	p.pos += 3
	p.skipFirstNewline()
	var buf []byte
	for {
		i := p.pos
		for i < len(src) {
			c := src[i]
			if c == '\'' || c == '\r' || (c < 0x20 && c != '\t' && c != '\n') || c == 0x7f {
				break
			}
			i++
		}
		buf = append(buf, src[p.pos:i]...)
		p.pos = i
		if i >= len(src) {
			p.fail("unterminated multi-line literal string")
		}
		switch src[i] {
		case '\'':
			j := i
			for j < len(src) && src[j] == '\'' {
				j++
			}
			n := j - i
			p.pos = j
			if n < 3 {
				for ; n > 0; n-- {
					buf = append(buf, '\'')
				}
				continue
			}
			if n > 5 {
				p.failAt(i, "too many quotes in multi-line literal string")
			}
			for ; n > 3; n-- {
				buf = append(buf, '\'')
			}
			return string(buf)
		case '\r':
			buf = append(buf, '\n')
			p.pos += 2
		default:
			p.failAt(i, "invalid character in multi-line literal string")
		}
	}
}
