package toml

import (
	"bytes"
	"unicode/utf8"
)

// Parse parses a TOML 1.0.0 document and returns its root table.
//
// The document must be valid UTF-8, must not start with a byte-order mark and
// must not contain a carriage return that is not part of a CRLF newline. On
// any violation of the grammar or of the table rules Parse returns a
// *SyntaxError.
func Parse(doc []byte) (root *Node, err error) {
	if off, msg := validateBytes(doc); msg != "" {
		return nil, newSyntaxError(doc, off, msg)
	}
	p := &parser{src: doc}
	defer func() {
		if r := recover(); r != nil {
			a, ok := r.(parseAbort)
			if !ok {
				panic(r)
			}
			root, err = nil, newSyntaxError(doc, a.off, a.msg)
		}
	}()
	p.root = NewTable()
	p.root.flags = flagExplicit
	p.cur = p.root
	p.document()
	return p.root, nil
}

// validateBytes performs the whole-document checks: UTF-8 validity, leading
// BOM and lone carriage returns.
func validateBytes(doc []byte) (int, string) {
	if bytes.HasPrefix(doc, []byte("\xef\xbb\xbf")) {
		return 0, "byte-order mark is not allowed"
	}
	if !utf8.Valid(doc) {
		// Locate the first bad sequence for the error offset.
		for i := 0; i < len(doc); {
			r, size := utf8.DecodeRune(doc[i:])
			if r == utf8.RuneError && size <= 1 {
				return i, "invalid UTF-8"
			}
			i += size
		}
		return 0, "invalid UTF-8"
	}
	for i := 0; ; {
		j := bytes.IndexByte(doc[i:], '\r')
		if j < 0 {
			break
		}
		i += j
		if i+1 >= len(doc) || doc[i+1] != '\n' {
			return i, "carriage return not followed by line feed"
		}
		i += 2
	}
	return 0, ""
}

// parser is a single-pass recursive-descent parser over the document bytes.
type parser struct {
	src  []byte
	pos  int
	root *Node
	cur  *Node // table receiving key/value pairs
}

func (p *parser) fail(msg string) {
	panic(parseAbort{p.pos, msg})
}

func (p *parser) failAt(off int, msg string) {
	panic(parseAbort{off, msg})
}

// document parses statements until end of input.
func (p *parser) document() {
	for {
		p.skipSpace()
		if p.pos >= len(p.src) {
			return
		}
		switch p.src[p.pos] {
		case '#':
			p.skipComment()
		case '\n':
			p.pos++
		case '\r':
			p.pos += 2 // validated: always CRLF
		case '[':
			p.header()
			p.endOfStatement()
		default:
			p.keyValue()
			p.endOfStatement()
		}
	}
}

// skipSpace skips spaces and tabs.
func (p *parser) skipSpace() {
	for p.pos < len(p.src) && (p.src[p.pos] == ' ' || p.src[p.pos] == '\t') {
		p.pos++
	}
}

// skipComment skips a comment starting at '#', up to (not including) the
// newline, rejecting forbidden control characters.
func (p *parser) skipComment() {
	p.pos++
	for p.pos < len(p.src) {
		c := p.src[p.pos]
		if c == '\n' || c == '\r' {
			return
		}
		if (c < 0x20 && c != '\t') || c == 0x7f {
			p.fail("control character in comment")
		}
		p.pos++
	}
}

// endOfStatement requires only whitespace and an optional comment before the
// next newline or the end of the document. It leaves the newline unconsumed.
func (p *parser) endOfStatement() {
	p.skipSpace()
	if p.pos >= len(p.src) {
		return
	}
	switch p.src[p.pos] {
	case '#':
		p.skipComment()
	case '\n', '\r':
	default:
		p.fail("unexpected characters after statement")
	}
}

// skipSpaceNewlinesComments skips whitespace, newlines and comments (used
// inside arrays).
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

// ---- keys -------------------------------------------------------------

var bareKeyByte = func() (t [256]bool) {
	for c := 'a'; c <= 'z'; c++ {
		t[c] = true
		t[c-32] = true
	}
	for c := '0'; c <= '9'; c++ {
		t[c] = true
	}
	t['_'], t['-'] = true, true
	return
}()

// key parses a possibly dotted key.
func (p *parser) key() []string {
	var keys []string
	for {
		p.skipSpace()
		keys = append(keys, p.simpleKey())
		p.skipSpace()
		if p.pos < len(p.src) && p.src[p.pos] == '.' {
			p.pos++
			continue
		}
		return keys
	}
}

func (p *parser) simpleKey() string {
	if p.pos >= len(p.src) {
		p.fail("expected key")
	}
	switch p.src[p.pos] {
	case '"':
		return p.basicString()
	case '\'':
		return p.literalString()
	}
	start := p.pos
	for p.pos < len(p.src) && bareKeyByte[p.src[p.pos]] {
		p.pos++
	}
	if p.pos == start {
		p.fail("expected key")
	}
	return string(p.src[start:p.pos])
}

// ---- statements -------------------------------------------------------

// header parses a [table] or [[array-of-tables]] header and makes the
// resulting table current.
func (p *parser) header() {
	p.pos++ // '['
	aot := p.pos < len(p.src) && p.src[p.pos] == '['
	if aot {
		p.pos++
	}
	keys := p.key()
	p.skipSpace()
	if p.pos >= len(p.src) || p.src[p.pos] != ']' {
		p.fail("expected ']' in table header")
	}
	p.pos++
	if aot {
		if p.pos >= len(p.src) || p.src[p.pos] != ']' {
			p.fail("expected ']]' in array-of-tables header")
		}
		p.pos++
		p.cur = p.openArrayTable(keys)
	} else {
		p.cur = p.openTable(keys)
	}
}

// keyValue parses "key = value" and stores it in the current table.
func (p *parser) keyValue() {
	keyOff := p.pos
	p.pairInto(p.cur, keyOff)
}

// pairInto parses "key = value" and inserts it into table t, resolving dotted
// keys relative to t.
func (p *parser) pairInto(t *Node, keyOff int) {
	keys := p.key()
	p.skipSpace()
	if p.pos >= len(p.src) || p.src[p.pos] != '=' {
		p.fail("expected '=' after key")
	}
	p.pos++
	p.skipSpace()
	val := p.value()
	if msg := insertPair(t, keys, val); msg != "" {
		p.failAt(keyOff, msg)
	}
}

// ---- table resolution (rules 1-6 of the TOML table semantics) ------------

// insertPair inserts val under the dotted key path in table t. Missing
// intermediate segments become dotted tables. It returns an error message, or
// "" on success.
func insertPair(t *Node, keys []string, val *Node) string {
	last := len(keys) - 1
	for _, k := range keys[:last] {
		child, ok := t.tbl[k]
		if !ok {
			child = &Node{kind: Table, flags: flagDotted, tbl: make(map[string]*Node)}
			t.tbl[k] = child
		} else if child.kind != Table || child.flags&(flagExplicit|flagSealed) != 0 {
			return "dotted key conflicts with an existing definition"
		}
		t = child
	}
	if _, dup := t.tbl[keys[last]]; dup {
		return "duplicate key"
	}
	t.tbl[keys[last]] = val
	return ""
}

// walk resolves the intermediate segments of a header path, creating
// implicit tables as needed, and returns the table that holds the last
// segment.
func (p *parser) walk(keys []string) *Node {
	t := p.root
	for _, k := range keys[:len(keys)-1] {
		child, ok := t.tbl[k]
		if !ok {
			child = &Node{kind: Table, tbl: make(map[string]*Node)}
			t.tbl[k] = child
		} else {
			switch child.kind {
			case Table:
				if child.flags&flagSealed != 0 {
					p.fail("table header passes through an inline table")
				}
			case Array:
				if child.flags&flagAoT == 0 {
					p.fail("table header passes through an array")
				}
				child = child.arr[len(child.arr)-1]
			default:
				p.fail("table header passes through a non-table")
			}
		}
		t = child
	}
	return t
}

func (p *parser) openTable(keys []string) *Node {
	t := p.walk(keys)
	k := keys[len(keys)-1]
	child, ok := t.tbl[k]
	if !ok {
		child = &Node{kind: Table, flags: flagExplicit, tbl: make(map[string]*Node)}
		t.tbl[k] = child
		return child
	}
	if child.kind != Table || child.flags&(flagExplicit|flagDotted|flagSealed) != 0 {
		p.fail("table redefined")
	}
	child.flags |= flagExplicit
	return child
}

func (p *parser) openArrayTable(keys []string) *Node {
	t := p.walk(keys)
	k := keys[len(keys)-1]
	elem := &Node{kind: Table, flags: flagExplicit, tbl: make(map[string]*Node)}
	child, ok := t.tbl[k]
	if !ok {
		t.tbl[k] = &Node{kind: Array, flags: flagAoT, arr: []*Node{elem}}
		return elem
	}
	if child.kind != Array || child.flags&flagAoT == 0 {
		p.fail("array of tables conflicts with an existing definition")
	}
	child.arr = append(child.arr, elem)
	return elem
}

// seal marks t and the tables created inside it by dotted keys as closed.
// Tables that are already sealed (nested inline tables) are not walked again.
func seal(t *Node) {
	if t.flags&flagSealed != 0 {
		return
	}
	t.flags |= flagSealed
	for _, c := range t.tbl {
		if c.kind == Table {
			seal(c)
		}
	}
}
