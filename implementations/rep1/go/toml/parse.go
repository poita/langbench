package toml

import (
	"bytes"
	"unicode/utf8"
)

// parser is a single-pass recursive-descent TOML parser. It walks src with
// one integer cursor; failures are signalled by panicking with *SyntaxError,
// which Parse recovers.
type parser struct {
	src     []byte
	pos     int
	root    *Table
	cur     *Table   // table receiving key/value pairs at top level
	keyBuf  []string // scratch for key paths
	scratch []byte   // scratch for strings with escapes
}

// Parse parses a TOML 1.0.0 document. On failure the error is a
// [*SyntaxError].
func Parse(src []byte) (root *Table, err error) {
	p := &parser{src: src, root: NewTable()}
	p.cur = p.root
	defer func() {
		if r := recover(); r != nil {
			se, ok := r.(*SyntaxError)
			if !ok {
				panic(r)
			}
			root, err = nil, se
		}
	}()
	p.validate()
	p.document()
	return p.root, nil
}

func (p *parser) fail(msg string) {
	panic(&SyntaxError{Line: lineOf(p.src, p.pos), Offset: p.pos, Msg: msg})
}

// validate checks the byte stream: valid UTF-8, no BOM, no lone CR.
func (p *parser) validate() {
	src := p.src
	if !utf8.Valid(src) {
		// Locate the offending byte for the error message.
		for i := 0; i < len(src); {
			r, n := utf8.DecodeRune(src[i:])
			if r == utf8.RuneError && n <= 1 {
				p.pos = i
				break
			}
			i += n
		}
		p.fail("invalid UTF-8")
	}
	if bytes.HasPrefix(src, []byte("\xef\xbb\xbf")) {
		p.pos = 0
		p.fail("byte-order mark is not allowed")
	}
	for i := 0; ; {
		j := bytes.IndexByte(src[i:], '\r')
		if j < 0 {
			break
		}
		i += j
		if i+1 >= len(src) || src[i+1] != '\n' {
			p.pos = i
			p.fail("bare carriage return")
		}
		i += 2
	}
}

func (p *parser) eof() bool { return p.pos >= len(p.src) }

// document parses the whole input as a sequence of lines.
func (p *parser) document() {
	for {
		p.skipWS()
		if p.eof() {
			return
		}
		switch p.src[p.pos] {
		case '#':
			p.skipComment()
		case '\n':
			p.pos++
		case '\r':
			p.pos += 2 // validate guarantees LF follows
		case '[':
			p.header()
			p.endOfLine()
		default:
			p.keyValue(p.cur)
			p.endOfLine()
		}
	}
}

// skipWS skips spaces and tabs.
func (p *parser) skipWS() {
	for p.pos < len(p.src) && (p.src[p.pos] == ' ' || p.src[p.pos] == '\t') {
		p.pos++
	}
}

// skipComment skips a comment, leaving the cursor on the terminating newline
// (or at end of input). The cursor must be on '#'.
func (p *parser) skipComment() {
	src := p.src
	i := p.pos + 1
	for i < len(src) {
		c := src[i]
		if c == '\n' || c == '\r' {
			break
		}
		if (c < 0x20 && c != '\t') || c == 0x7f {
			p.pos = i
			p.fail("control character in comment")
		}
		i++
	}
	p.pos = i
}

// skipSpace skips whitespace, newlines and comments (used inside arrays).
func (p *parser) skipSpace() {
	for p.pos < len(p.src) {
		switch p.src[p.pos] {
		case ' ', '\t', '\n':
			p.pos++
		case '\r':
			p.pos += 2
		case '#':
			p.skipComment()
		default:
			return
		}
	}
}

// endOfLine consumes trailing whitespace, an optional comment and the
// newline (or end of input) after a statement.
func (p *parser) endOfLine() {
	p.skipWS()
	if p.eof() {
		return
	}
	if p.src[p.pos] == '#' {
		p.skipComment()
		if p.eof() {
			return
		}
	}
	switch p.src[p.pos] {
	case '\n':
		p.pos++
	case '\r':
		p.pos += 2
	default:
		p.fail("unexpected characters after statement")
	}
}

// header parses a [table] or [[array-of-tables]] header line and makes the
// addressed table current.
func (p *parser) header() {
	aot := p.pos+1 < len(p.src) && p.src[p.pos+1] == '['
	if aot {
		p.pos += 2
	} else {
		p.pos++
	}
	path := p.parseKey(p.keyBuf[:0])
	p.keyBuf = path[:0]
	if p.pos >= len(p.src) || p.src[p.pos] != ']' {
		p.fail("expected ']' in table header")
	}
	p.pos++
	if aot {
		if p.pos >= len(p.src) || p.src[p.pos] != ']' {
			p.fail("expected ']]' in array-of-tables header")
		}
		p.pos++
	}
	p.cur = p.openTable(path, aot)
}

// keyValue parses `key = value` and stores it in the table t.
func (p *parser) keyValue(t *Table) {
	path := p.parseKey(p.keyBuf[:0])
	p.keyBuf = path[:0]
	if p.pos >= len(p.src) || p.src[p.pos] != '=' {
		p.fail("expected '=' after key")
	}
	p.pos++
	p.skipWS()
	// Resolve the parent before parsing the value: the value may reuse keyBuf.
	parent := p.resolveDotted(t, path[:len(path)-1])
	last := path[len(path)-1]
	if _, dup := parent.m[last]; dup {
		p.fail("duplicate key " + last)
	}
	v := p.value()
	parent.m[last] = v
}

// parseKey parses a possibly dotted key, appending its segments to dst, and
// skips the whitespace around it.
func (p *parser) parseKey(dst []string) []string {
	for {
		p.skipWS()
		dst = append(dst, p.simpleKey())
		p.skipWS()
		if p.pos < len(p.src) && p.src[p.pos] == '.' {
			p.pos++
			continue
		}
		return dst
	}
}

func isBareKeyByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-'
}

func (p *parser) simpleKey() string {
	if p.eof() {
		p.fail("expected key")
	}
	switch c := p.src[p.pos]; {
	case c == '"':
		return p.basicString()
	case c == '\'':
		return p.literalString()
	case isBareKeyByte(c):
		start := p.pos
		for p.pos < len(p.src) && isBareKeyByte(p.src[p.pos]) {
			p.pos++
		}
		return string(p.src[start:p.pos])
	}
	p.fail("expected key")
	return ""
}

// value parses any TOML value at the cursor.
func (p *parser) value() Node {
	if p.eof() {
		p.fail("expected value")
	}
	switch c := p.src[p.pos]; c {
	case '"':
		if bytes.HasPrefix(p.src[p.pos:], []byte(`"""`)) {
			return &Value{String, p.multilineBasicString()}
		}
		return &Value{String, p.basicString()}
	case '\'':
		if bytes.HasPrefix(p.src[p.pos:], []byte("'''")) {
			return &Value{String, p.multilineLiteralString()}
		}
		return &Value{String, p.literalString()}
	case '[':
		return p.array()
	case '{':
		return p.inlineTable()
	}
	return p.scalar()
}

func (p *parser) array() Node {
	p.pos++ // '['
	arr := &Array{}
	for {
		p.skipSpace()
		if p.eof() {
			p.fail("unterminated array")
		}
		if p.src[p.pos] == ']' {
			p.pos++
			return arr
		}
		arr.Elems = append(arr.Elems, p.value())
		p.skipSpace()
		if p.eof() {
			p.fail("unterminated array")
		}
		switch p.src[p.pos] {
		case ',':
			p.pos++
		case ']':
			p.pos++
			return arr
		default:
			p.fail("expected ',' or ']' in array")
		}
	}
}

func (p *parser) inlineTable() Node {
	p.pos++ // '{'
	t := NewTable()
	t.explicit = true
	p.skipWS()
	if p.pos < len(p.src) && p.src[p.pos] == '}' {
		p.pos++
		t.sealed = true
		return t
	}
	for {
		p.skipWS()
		p.keyValue(t)
		p.skipWS()
		if p.eof() {
			p.fail("unterminated inline table")
		}
		switch p.src[p.pos] {
		case ',':
			p.pos++
		case '}':
			p.pos++
			t.seal()
			return t
		default:
			p.fail("expected ',' or '}' in inline table")
		}
	}
}
