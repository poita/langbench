package toml

// value parses any TOML value at the cursor.
func (p *parser) value() *Node {
	if p.pos >= len(p.src) {
		p.fail("expected value")
	}
	switch p.src[p.pos] {
	case '"':
		if p.hasPrefix(`"""`) {
			return NewString(p.multiBasicString())
		}
		return NewString(p.basicString())
	case '\'':
		if p.hasPrefix(`'''`) {
			return NewString(p.multiLiteralString())
		}
		return NewString(p.literalString())
	case '[':
		return p.array()
	case '{':
		return p.inlineTable()
	}
	return p.scalar()
}

func (p *parser) hasPrefix(s string) bool {
	return len(p.src)-p.pos >= len(s) && string(p.src[p.pos:p.pos+len(s)]) == s
}

// array parses "[ v, v, ... ]" with free whitespace, newlines and comments.
func (p *parser) array() *Node {
	p.pos++ // '['
	arr := &Node{kind: Array}
	for {
		p.skipSpaceNewlinesComments()
		if p.pos >= len(p.src) {
			p.fail("unterminated array")
		}
		if p.src[p.pos] == ']' {
			p.pos++
			return arr
		}
		arr.arr = append(arr.arr, p.value())
		p.skipSpaceNewlinesComments()
		if p.pos >= len(p.src) {
			p.fail("unterminated array")
		}
		switch p.src[p.pos] {
		case ',':
			p.pos++
		case ']':
		default:
			p.fail("expected ',' or ']' in array")
		}
	}
}

// inlineTable parses "{ k = v, ... }" on a single line.
func (p *parser) inlineTable() *Node {
	p.pos++ // '{'
	t := &Node{kind: Table, flags: flagExplicit, tbl: make(map[string]*Node)}
	p.skipSpace()
	if p.pos < len(p.src) && p.src[p.pos] == '}' {
		p.pos++
		t.flags |= flagSealed
		return t
	}
	for {
		p.skipSpace()
		p.pairInto(t, p.pos)
		p.skipSpace()
		if p.pos >= len(p.src) {
			p.fail("unterminated inline table")
		}
		switch p.src[p.pos] {
		case ',':
			p.pos++
		case '}':
			p.pos++
			seal(t)
			return t
		default:
			p.fail("expected ',' or '}' in inline table")
		}
	}
}
