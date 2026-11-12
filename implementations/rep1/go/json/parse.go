package jsoncanon

// MaxDepth is the maximum nesting depth of arrays and objects. A top-level
// array or object has depth 1.
const MaxDepth = 512

// Parse validates data as a complete JSON document and returns its value tree.
//
// The whole input is checked: it must be well-formed UTF-8 without a byte
// order mark, and exactly one JSON value surrounded by optional whitespace
// (space, tab, LF, CR). Arrays and objects are nested at most [MaxDepth]
// levels deep.
//
// Strings in the tree are decoded. Numbers hold their canonical text: the
// lexeme as written, except that an exponent is rewritten as a lowercase "e",
// no "+", no leading zeros and no sign on a zero exponent. Objects keep all
// members, duplicates included, in input order.
//
// Errors are of type *[SyntaxError].
func Parse(data []byte) (*Value, error) {
	if off := invalidUTF8Offset(data); off >= 0 {
		return nil, &SyntaxError{off, "invalid UTF-8"}
	}
	if len(data) >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF {
		return nil, &SyntaxError{0, "byte order mark"}
	}
	p := parser{data: data}
	p.skipWS()
	v, err := p.value(0)
	if err != nil {
		return nil, err
	}
	p.skipWS()
	if p.pos != len(data) {
		return nil, p.errf("unexpected data after document")
	}
	return &v, nil
}

type parser struct {
	data []byte
	pos  int
}

func (p *parser) errf(msg string) error {
	return &SyntaxError{p.pos, msg}
}

func (p *parser) skipWS() {
	d := p.data
	i := p.pos
	for i < len(d) {
		switch d[i] {
		case ' ', '\t', '\n', '\r':
			i++
			continue
		}
		break
	}
	p.pos = i
}

// value parses one value starting at p.pos. depth is the number of enclosing
// containers.
func (p *parser) value(depth int) (Value, error) {
	if p.pos >= len(p.data) {
		return Value{}, p.errf("unexpected end of input")
	}
	switch c := p.data[p.pos]; c {
	case '{':
		return p.object(depth + 1)
	case '[':
		return p.array(depth + 1)
	case '"':
		s, err := p.str()
		return Value{Kind: String, Text: s}, err
	case 't':
		return p.literal("true", Value{Kind: Bool, Bool: true})
	case 'f':
		return p.literal("false", Value{Kind: Bool})
	case 'n':
		return p.literal("null", Value{Kind: Null})
	default:
		if c == '-' || (c >= '0' && c <= '9') {
			return p.number()
		}
		return Value{}, p.errf("unexpected character")
	}
}

func (p *parser) literal(word string, v Value) (Value, error) {
	if len(p.data)-p.pos < len(word) || string(p.data[p.pos:p.pos+len(word)]) != word {
		return Value{}, p.errf("invalid literal")
	}
	p.pos += len(word)
	return v, nil
}

func (p *parser) array(depth int) (Value, error) {
	if depth > MaxDepth {
		return Value{}, p.errf("nesting too deep")
	}
	p.pos++ // '['
	v := Value{Kind: Array}
	p.skipWS()
	if p.pos < len(p.data) && p.data[p.pos] == ']' {
		p.pos++
		return v, nil
	}
	for {
		p.skipWS()
		e, err := p.value(depth)
		if err != nil {
			return Value{}, err
		}
		v.Elems = append(v.Elems, e)
		p.skipWS()
		if p.pos >= len(p.data) {
			return Value{}, p.errf("unterminated array")
		}
		switch p.data[p.pos] {
		case ',':
			p.pos++
		case ']':
			p.pos++
			return v, nil
		default:
			return Value{}, p.errf("expected ',' or ']'")
		}
	}
}

func (p *parser) object(depth int) (Value, error) {
	if depth > MaxDepth {
		return Value{}, p.errf("nesting too deep")
	}
	p.pos++ // '{'
	v := Value{Kind: Object}
	p.skipWS()
	if p.pos < len(p.data) && p.data[p.pos] == '}' {
		p.pos++
		return v, nil
	}
	for {
		p.skipWS()
		if p.pos >= len(p.data) || p.data[p.pos] != '"' {
			return Value{}, p.errf("expected string key")
		}
		k, err := p.str()
		if err != nil {
			return Value{}, err
		}
		p.skipWS()
		if p.pos >= len(p.data) || p.data[p.pos] != ':' {
			return Value{}, p.errf("expected ':'")
		}
		p.pos++
		p.skipWS()
		e, err := p.value(depth)
		if err != nil {
			return Value{}, err
		}
		v.Members = append(v.Members, Member{k, e})
		p.skipWS()
		if p.pos >= len(p.data) {
			return Value{}, p.errf("unterminated object")
		}
		switch p.data[p.pos] {
		case ',':
			p.pos++
		case '}':
			p.pos++
			return v, nil
		default:
			return Value{}, p.errf("expected ',' or '}'")
		}
	}
}
