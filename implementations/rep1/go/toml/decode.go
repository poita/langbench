package toml

import (
	"bytes"
	"fmt"
	"unicode/utf8"
)

// SyntaxError describes why a document is not valid TOML.
type SyntaxError struct {
	Line   int // 1-based line number
	Offset int // byte offset into the document
	Msg    string
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("toml: line %d: %s", e.Line, e.Msg)
}

// Parse parses a TOML 1.0.0 document. On failure the error is a
// *SyntaxError.
func Parse(data []byte) (root *Table, err error) {
	p := &parser{data: data}
	defer func() {
		if r := recover(); r != nil {
			se, ok := r.(*SyntaxError)
			if !ok {
				panic(r)
			}
			root, err = nil, se
		}
	}()
	p.precheck()
	root = NewTable()
	p.document(root)
	return root, nil
}

type parser struct {
	data []byte
	pos  int
}

func (p *parser) fail(format string, args ...any) {
	off := p.pos
	if off > len(p.data) {
		off = len(p.data)
	}
	line := 1 + bytes.Count(p.data[:off], []byte{'\n'})
	panic(&SyntaxError{Line: line, Offset: off, Msg: fmt.Sprintf(format, args...)})
}

// precheck rejects whole-document encoding problems: invalid UTF-8, a
// byte-order mark, and any CR that is not part of a CRLF pair.
func (p *parser) precheck() {
	d := p.data
	if !utf8.Valid(d) {
		p.fail("invalid UTF-8")
	}
	if bytes.HasPrefix(d, []byte("\xef\xbb\xbf")) {
		p.pos = 0
		p.fail("byte-order mark")
	}
	for i := 0; ; {
		j := bytes.IndexByte(d[i:], '\r')
		if j < 0 {
			return
		}
		i += j
		if i+1 >= len(d) || d[i+1] != '\n' {
			p.pos = i
			p.fail("bare carriage return")
		}
		i += 2
	}
}

// --- low-level helpers ---

func (p *parser) eof() bool { return p.pos >= len(p.data) }

func (p *parser) peek() byte {
	if p.pos < len(p.data) {
		return p.data[p.pos]
	}
	return 0
}

func (p *parser) at(s string) bool {
	return bytes.HasPrefix(p.data[p.pos:], []byte(s))
}

func (p *parser) skipWS() {
	for p.pos < len(p.data) && (p.data[p.pos] == ' ' || p.data[p.pos] == '\t') {
		p.pos++
	}
}

func (p *parser) atNewline() bool {
	return p.pos < len(p.data) && (p.data[p.pos] == '\n' ||
		(p.data[p.pos] == '\r' && p.pos+1 < len(p.data) && p.data[p.pos+1] == '\n'))
}

func (p *parser) skipNewline() {
	if p.data[p.pos] == '\r' {
		p.pos++
	}
	p.pos++
}

// skipComment skips a comment starting at '#', if there is one.
func (p *parser) skipComment() {
	if p.peek() != '#' || p.eof() {
		return
	}
	for p.pos < len(p.data) {
		c := p.data[p.pos]
		if c == '\n' || c == '\r' {
			return
		}
		if (c < 0x20 && c != '\t') || c == 0x7f {
			p.fail("control character in comment")
		}
		p.pos++
	}
}

// skipTrivia skips whitespace, comments and newlines (inside arrays).
func (p *parser) skipTrivia() {
	for {
		p.skipWS()
		p.skipComment()
		if p.atNewline() {
			p.skipNewline()
			continue
		}
		return
	}
}

// endOfLine requires only whitespace and an optional comment before the
// newline or end of file, and consumes the newline.
func (p *parser) endOfLine() {
	p.skipWS()
	p.skipComment()
	if p.eof() {
		return
	}
	if !p.atNewline() {
		p.fail("unexpected character %q", p.data[p.pos])
	}
	p.skipNewline()
}

// --- statements ---

func (p *parser) document(root *Table) {
	cur := root
	for {
		p.skipWS()
		if p.eof() {
			return
		}
		switch {
		case p.peek() == '#':
			p.skipComment()
			p.endOfLine()
		case p.atNewline():
			p.skipNewline()
		case p.peek() == '[':
			cur = p.header(root)
			p.endOfLine()
		default:
			p.keyValue(cur)
			p.endOfLine()
		}
	}
}

func (p *parser) keyValue(t *Table) {
	key := p.key()
	p.skipWS()
	if p.peek() != '=' || p.eof() {
		p.fail("expected '='")
	}
	p.pos++
	p.skipWS()
	v := p.value()
	p.setDotted(t, key, v)
}

// setDotted stores v at the dotted key below t.
func (p *parser) setDotted(t *Table, key []string, v Node) {
	last := len(key) - 1
	for _, seg := range key[:last] {
		c, ok := t.entries[seg]
		if !ok {
			nt := NewTable()
			nt.state = stateDotted
			t.entries[seg] = nt
			t = nt
			continue
		}
		nt, ok := c.(*Table)
		if !ok || nt.state == stateExplicit || nt.state == stateInline {
			p.fail("key %q is already defined", seg)
		}
		nt.state = stateDotted
		t = nt
	}
	if _, dup := t.entries[key[last]]; dup {
		p.fail("duplicate key %q", key[last])
	}
	t.entries[key[last]] = v
}

// header parses a [table] or [[array-of-tables]] line and returns the table
// that subsequent key/value pairs belong to.
func (p *parser) header(root *Table) *Table {
	array := p.at("[[")
	if array {
		p.pos += 2
	} else {
		p.pos++
	}
	p.skipWS()
	key := p.key()
	p.skipWS()
	if array {
		if !p.at("]]") {
			p.fail("expected ']]'")
		}
		p.pos += 2
	} else {
		if p.peek() != ']' || p.eof() {
			p.fail("expected ']'")
		}
		p.pos++
	}

	t := root
	last := len(key) - 1
	for _, seg := range key[:last] {
		c, ok := t.entries[seg]
		if !ok {
			nt := NewTable()
			t.entries[seg] = nt
			t = nt
			continue
		}
		switch c := c.(type) {
		case *Table:
			if c.state == stateInline {
				p.fail("cannot extend inline table %q", seg)
			}
			t = c
		case *Array:
			if !c.tables {
				p.fail("cannot extend array %q", seg)
			}
			t = c.Items[len(c.Items)-1].(*Table)
		default:
			p.fail("key %q is not a table", seg)
		}
	}

	name := key[last]
	c, exists := t.entries[name]
	if array {
		nt := NewTable()
		nt.state = stateExplicit
		if !exists {
			t.entries[name] = &Array{Items: []Node{nt}, tables: true}
			return nt
		}
		arr, ok := c.(*Array)
		if !ok || !arr.tables {
			p.fail("key %q is not an array of tables", name)
		}
		arr.Items = append(arr.Items, nt)
		return nt
	}
	if !exists {
		nt := NewTable()
		nt.state = stateExplicit
		t.entries[name] = nt
		return nt
	}
	nt, ok := c.(*Table)
	if !ok || nt.state != stateImplicit {
		p.fail("table %q is already defined", name)
	}
	nt.state = stateExplicit
	return nt
}

// --- keys ---

func isBareKeyChar(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-'
}

// key parses a possibly dotted key. Surrounding whitespace is left to the
// caller, except around the dots.
func (p *parser) key() []string {
	var parts []string
	for {
		p.skipWS()
		parts = append(parts, p.simpleKey())
		p.skipWS()
		if p.peek() != '.' || p.eof() {
			return parts
		}
		p.pos++
	}
}

func (p *parser) simpleKey() string {
	if p.eof() {
		p.fail("expected key")
	}
	switch c := p.data[p.pos]; {
	case c == '"':
		p.pos++
		return p.basicString()
	case c == '\'':
		p.pos++
		return p.literalString()
	case isBareKeyChar(c):
		start := p.pos
		for p.pos < len(p.data) && isBareKeyChar(p.data[p.pos]) {
			p.pos++
		}
		return string(p.data[start:p.pos])
	}
	p.fail("expected key")
	return ""
}

// --- values ---

func (p *parser) value() Node {
	if p.eof() {
		p.fail("expected value")
	}
	switch p.data[p.pos] {
	case '"':
		if p.at(`"""`) {
			p.pos += 3
			return &Value{TypeString, p.multiBasicString()}
		}
		p.pos++
		return &Value{TypeString, p.basicString()}
	case '\'':
		if p.at(`'''`) {
			p.pos += 3
			return &Value{TypeString, p.multiLiteralString()}
		}
		p.pos++
		return &Value{TypeString, p.literalString()}
	case '[':
		return p.array()
	case '{':
		return p.inlineTable()
	}
	return p.scalarToken()
}

func (p *parser) array() Node {
	p.pos++ // [
	arr := &Array{}
	for {
		p.skipTrivia()
		if p.eof() {
			p.fail("unterminated array")
		}
		if p.data[p.pos] == ']' {
			p.pos++
			return arr
		}
		arr.Items = append(arr.Items, p.value())
		p.skipTrivia()
		if p.eof() {
			p.fail("unterminated array")
		}
		switch p.data[p.pos] {
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
	p.pos++ // {
	t := NewTable()
	t.state = stateInline
	p.skipWS()
	if p.peek() == '}' && !p.eof() {
		p.pos++
		return t
	}
	for {
		p.skipWS()
		key := p.key()
		p.skipWS()
		if p.peek() != '=' || p.eof() {
			p.fail("expected '=' in inline table")
		}
		p.pos++
		p.skipWS()
		v := p.value()
		p.setDotted(t, key, v)
		p.skipWS()
		if p.eof() {
			p.fail("unterminated inline table")
		}
		switch p.data[p.pos] {
		case ',':
			p.pos++
		case '}':
			p.pos++
			return t
		default:
			p.fail("expected ',' or '}' in inline table")
		}
	}
}
