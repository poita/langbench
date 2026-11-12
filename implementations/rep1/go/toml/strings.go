package toml

import (
	"strings"
	"unicode/utf8"
)

// The scanners below are entered just after the opening delimiter and
// return the decoded string, having consumed the closing delimiter.

func isForbiddenControl(c byte) bool {
	return (c < 0x20 && c != '\t') || c == 0x7f
}

func hexVal(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10
	}
	return -1
}

func (p *parser) basicString() string {
	start := p.pos
	// Fast path: no escapes.
	for p.pos < len(p.data) {
		c := p.data[p.pos]
		if c == '"' {
			s := string(p.data[start:p.pos])
			p.pos++
			return s
		}
		if c == '\\' {
			break
		}
		if isForbiddenControl(c) {
			p.fail("control character in string")
		}
		p.pos++
	}
	var sb strings.Builder
	sb.Write(p.data[start:p.pos])
	for {
		if p.eof() {
			p.fail("unterminated string")
		}
		c := p.data[p.pos]
		switch {
		case c == '"':
			p.pos++
			return sb.String()
		case c == '\\':
			p.pos++
			p.escape(&sb)
		case isForbiddenControl(c):
			p.fail("control character in string")
		default:
			sb.WriteByte(c)
			p.pos++
		}
	}
}

// escape decodes the escape sequence after a backslash.
func (p *parser) escape(sb *strings.Builder) {
	if p.eof() {
		p.fail("unterminated escape")
	}
	c := p.data[p.pos]
	p.pos++
	switch c {
	case 'b':
		sb.WriteByte('\b')
	case 't':
		sb.WriteByte('\t')
	case 'n':
		sb.WriteByte('\n')
	case 'f':
		sb.WriteByte('\f')
	case 'r':
		sb.WriteByte('\r')
	case '"':
		sb.WriteByte('"')
	case '\\':
		sb.WriteByte('\\')
	case 'u', 'U':
		n := 4
		if c == 'U' {
			n = 8
		}
		if p.pos+n > len(p.data) {
			p.fail("short unicode escape")
		}
		var r rune
		for _, h := range p.data[p.pos : p.pos+n] {
			v := hexVal(h)
			if v < 0 {
				p.fail("bad hex digit in unicode escape")
			}
			r = r<<4 | rune(v)
		}
		p.pos += n
		if !utf8.ValidRune(r) {
			p.fail("escape is not a Unicode scalar value")
		}
		sb.WriteRune(r)
	default:
		p.fail("invalid escape \\%c", c)
	}
}

func (p *parser) literalString() string {
	start := p.pos
	for p.pos < len(p.data) {
		c := p.data[p.pos]
		if c == '\'' {
			s := string(p.data[start:p.pos])
			p.pos++
			return s
		}
		if isForbiddenControl(c) {
			p.fail("control character in string")
		}
		p.pos++
	}
	p.fail("unterminated string")
	return ""
}

// openMultiline discards a newline directly after the opening delimiter.
func (p *parser) openMultiline() {
	if p.atNewline() {
		p.skipNewline()
	}
}

// quoteRun consumes a run of the delimiter byte q inside a multi-line
// string. It reports whether the run closed the string, and writes the
// quotes that belong to the value.
func (p *parser) quoteRun(q byte, sb *strings.Builder) (closed bool) {
	n := 0
	for p.pos < len(p.data) && p.data[p.pos] == q {
		n++
		p.pos++
	}
	switch {
	case n < 3:
		for i := 0; i < n; i++ {
			sb.WriteByte(q)
		}
		return false
	case n > 5:
		p.fail("too many quotes in multi-line string")
	}
	for i := 0; i < n-3; i++ {
		sb.WriteByte(q)
	}
	return true
}

func (p *parser) multiBasicString() string {
	p.openMultiline()
	var sb strings.Builder
	for {
		if p.eof() {
			p.fail("unterminated multi-line string")
		}
		c := p.data[p.pos]
		switch {
		case c == '"':
			if p.quoteRun('"', &sb) {
				return sb.String()
			}
		case c == '\\':
			p.pos++
			if p.lineEndingBackslash() {
				continue
			}
			p.escape(&sb)
		case c == '\n':
			sb.WriteByte('\n')
			p.pos++
		case c == '\r': // always CRLF: normalise to LF
			sb.WriteByte('\n')
			p.pos += 2
		case isForbiddenControl(c):
			p.fail("control character in string")
		default:
			sb.WriteByte(c)
			p.pos++
		}
	}
}

// lineEndingBackslash handles a backslash (already consumed) followed by
// optional whitespace and a newline, skipping all whitespace and newlines
// up to the next other character. It reports false, consuming nothing, if
// the backslash is not a line-ending one.
func (p *parser) lineEndingBackslash() bool {
	save := p.pos
	p.skipWS()
	if !p.atNewline() {
		p.pos = save
		return false
	}
	for {
		p.skipWS()
		if !p.atNewline() {
			return true
		}
		p.skipNewline()
	}
}

func (p *parser) multiLiteralString() string {
	p.openMultiline()
	var sb strings.Builder
	for {
		if p.eof() {
			p.fail("unterminated multi-line string")
		}
		c := p.data[p.pos]
		switch {
		case c == '\'':
			if p.quoteRun('\'', &sb) {
				return sb.String()
			}
		case c == '\n':
			sb.WriteByte('\n')
			p.pos++
		case c == '\r':
			sb.WriteByte('\n')
			p.pos += 2
		case isForbiddenControl(c):
			p.fail("control character in string")
		default:
			sb.WriteByte(c)
			p.pos++
		}
	}
}
