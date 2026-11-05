package toml

import (
	"bytes"
	"unicode/utf8"
)

// parser is a single-pass recursive-descent TOML parser over a byte slice.
// Failures are reported by panicking with *Error, recovered in Parse.
type parser struct {
	src  []byte
	pos  int
	root *Node
	cur  *Node // table that receives key/value pairs
}

// Parse parses a TOML 1.0.0 document and returns its root table. On failure it
// returns a nil node and an *Error.
func Parse(data []byte) (root *Node, err error) {
	p := &parser{src: data}
	defer func() {
		if r := recover(); r != nil {
			e, ok := r.(*Error)
			if !ok {
				panic(r)
			}
			root, err = nil, e
		}
	}()
	p.validate()
	p.root = NewTable()
	p.cur = p.root
	p.parseDocument()
	return p.root, nil
}

func (p *parser) fail(msg string) {
	panic(newError(p.src, p.pos, msg))
}

func (p *parser) failAt(off int, msg string) {
	panic(newError(p.src, off, msg))
}

// validate checks the byte stream as a whole: no BOM, valid UTF-8, and no CR
// that is not part of a CRLF.
func (p *parser) validate() {
	src := p.src
	if bytes.HasPrefix(src, []byte("\xef\xbb\xbf")) {
		p.failAt(0, "byte-order mark is not allowed")
	}
	if !utf8.Valid(src) {
		off := 0
		for off < len(src) {
			r, size := utf8.DecodeRune(src[off:])
			if r == utf8.RuneError && size <= 1 {
				break
			}
			off += size
		}
		p.failAt(off, "invalid UTF-8")
	}
	for off := 0; ; {
		i := bytes.IndexByte(src[off:], '\r')
		if i < 0 {
			break
		}
		off += i
		if off+1 >= len(src) || src[off+1] != '\n' {
			p.failAt(off, "carriage return not followed by line feed")
		}
		off += 2
	}
}

func (p *parser) eof() bool { return p.pos >= len(p.src) }

func (p *parser) skipWS() {
	for p.pos < len(p.src) {
		if c := p.src[p.pos]; c != ' ' && c != '\t' {
			return
		}
		p.pos++
	}
}

// skipComment consumes a comment starting at '#', leaving the cursor on the
// line terminator (or at end of input).
func (p *parser) skipComment() {
	src := p.src
	i := p.pos + 1
	for i < len(src) {
		c := src[i]
		if c == '\n' || c == '\r' {
			break
		}
		if (c < 0x20 && c != '\t') || c == 0x7f {
			p.failAt(i, "control character in comment")
		}
		i++
	}
	p.pos = i
}

// skipSpaceNewlinesComments skips whitespace, newlines and comments (inside arrays).
func (p *parser) skipSpaceNewlinesComments() {
	for p.pos < len(p.src) {
		switch p.src[p.pos] {
		case ' ', '\t', '\n', '\r':
			p.pos++
		case '#':
			p.skipComment()
		default:
			return
		}
	}
}

// endLine consumes trailing whitespace, an optional comment and the newline
// (or end of input) that must follow a statement.
func (p *parser) endLine() {
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
		p.fail("unexpected content after statement")
	}
}

func (p *parser) parseDocument() {
	for {
		p.skipWS()
		if p.eof() {
			return
		}
		switch p.src[p.pos] {
		case '\n':
			p.pos++
		case '\r':
			p.pos += 2
		case '#':
			p.skipComment()
		case '[':
			p.parseHeader()
			p.endLine()
		default:
			p.parseKeyValue()
			p.endLine()
		}
	}
}

// parseHeader parses "[a.b]" or "[[a.b]]" and opens the addressed table.
func (p *parser) parseHeader() {
	p.pos++ // '['
	aot := false
	if p.pos < len(p.src) && p.src[p.pos] == '[' {
		aot = true
		p.pos++
	}
	keys := p.parseKey()
	if p.pos >= len(p.src) || p.src[p.pos] != ']' {
		p.fail("expected ']'")
	}
	p.pos++
	if aot {
		if p.pos >= len(p.src) || p.src[p.pos] != ']' {
			p.fail("expected ']]'")
		}
		p.pos++
	}
	p.openTable(keys, aot)
}

// descend resolves one intermediate header segment below t.
func (p *parser) descend(t *Node, key string) *Node {
	child := t.tbl[key]
	if child == nil {
		child = NewTable()
		t.tbl[key] = child
		return child
	}
	switch child.kind {
	case KindTable:
		if child.flags&flagSealed != 0 {
			p.fail("cannot extend an inline table")
		}
		return child
	case KindArray:
		if child.flags&flagAOT != 0 && len(child.items) > 0 {
			return child.items[len(child.items)-1]
		}
	}
	p.fail("key is not a table")
	return nil
}

func (p *parser) openTable(keys []string, aot bool) {
	t := p.root
	for _, k := range keys[:len(keys)-1] {
		t = p.descend(t, k)
	}
	last := keys[len(keys)-1]
	child := t.tbl[last]
	if aot {
		if child == nil {
			child = &Node{kind: KindArray, flags: flagAOT}
			t.tbl[last] = child
		} else if child.kind != KindArray || child.flags&flagAOT == 0 {
			p.fail("not an array of tables")
		}
		nt := NewTable()
		nt.flags = flagExplicit
		child.items = append(child.items, nt)
		p.cur = nt
		return
	}
	if child == nil {
		child = NewTable()
		child.flags = flagExplicit
		t.tbl[last] = child
	} else if child.kind == KindTable && child.flags&(flagExplicit|flagDotted|flagSealed) == 0 {
		child.flags |= flagExplicit
	} else {
		p.fail("table is already defined")
	}
	p.cur = child
}

func (p *parser) parseKeyValue() {
	keys := p.parseKey()
	p.skipWS()
	if p.pos >= len(p.src) || p.src[p.pos] != '=' {
		p.fail("expected '='")
	}
	p.pos++
	p.skipWS()
	val := p.parseValue()
	p.insert(p.cur, keys, val)
}

// insert stores val at the (possibly dotted) key path below t.
func (p *parser) insert(t *Node, keys []string, val *Node) {
	for _, k := range keys[:len(keys)-1] {
		child := t.tbl[k]
		if child == nil {
			child = NewTable()
			child.flags = flagDotted
			t.tbl[k] = child
		} else if child.kind != KindTable || child.flags&(flagExplicit|flagSealed) != 0 {
			p.fail("dotted key conflicts with an existing definition")
		} else {
			child.flags |= flagDotted
		}
		t = child
	}
	last := keys[len(keys)-1]
	if _, dup := t.tbl[last]; dup {
		p.fail("duplicate key")
	}
	t.tbl[last] = val
}

// seal marks an inline table, and every table created inside it, as closed.
func seal(t *Node) {
	t.flags |= flagSealed
	for _, c := range t.tbl {
		if c.kind == KindTable && c.flags&flagSealed == 0 {
			seal(c)
		}
	}
}

func (p *parser) parseValue() *Node {
	if p.eof() {
		p.fail("expected a value")
	}
	switch c := p.src[p.pos]; c {
	case '"':
		if p.hasPrefix(`"""`) {
			return newScalar(KindString, p.parseMLBasic())
		}
		return newScalar(KindString, p.parseBasic())
	case '\'':
		if p.hasPrefix(`'''`) {
			return newScalar(KindString, p.parseMLLiteral())
		}
		return newScalar(KindString, p.parseLiteral())
	case '[':
		return p.parseArray()
	case '{':
		return p.parseInlineTable()
	}
	return p.parseScalar()
}

func (p *parser) hasPrefix(s string) bool {
	return len(p.src)-p.pos >= len(s) && string(p.src[p.pos:p.pos+len(s)]) == s
}

func (p *parser) parseArray() *Node {
	p.pos++ // '['
	arr := &Node{kind: KindArray}
	for {
		p.skipSpaceNewlinesComments()
		if p.eof() {
			p.fail("unterminated array")
		}
		if p.src[p.pos] == ']' {
			p.pos++
			return arr
		}
		arr.items = append(arr.items, p.parseValue())
		p.skipSpaceNewlinesComments()
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
			p.fail("expected ',' or ']'")
		}
	}
}

func (p *parser) parseInlineTable() *Node {
	p.pos++ // '{'
	tbl := NewTable()
	tbl.flags = flagExplicit
	p.skipWS()
	if p.pos < len(p.src) && p.src[p.pos] == '}' {
		p.pos++
		seal(tbl)
		return tbl
	}
	for {
		keys := p.parseKey()
		p.skipWS()
		if p.pos >= len(p.src) || p.src[p.pos] != '=' {
			p.fail("expected '='")
		}
		p.pos++
		p.skipWS()
		val := p.parseValue()
		p.insert(tbl, keys, val)
		p.skipWS()
		if p.eof() {
			p.fail("unterminated inline table")
		}
		switch p.src[p.pos] {
		case ',':
			p.pos++
			p.skipWS()
		case '}':
			p.pos++
			seal(tbl)
			return tbl
		default:
			p.fail("expected ',' or '}'")
		}
	}
}
