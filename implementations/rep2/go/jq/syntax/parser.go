package syntax

import (
	"example.com/jq/value"
)

var keywords = map[string]bool{
	"if": true, "then": true, "elif": true, "else": true, "end": true,
	"as": true, "reduce": true, "and": true, "or": true,
	"true": true, "false": true, "null": true,
}

// Parse parses a filter.
func Parse(src string) (Node, error) {
	toks, err := lex(src)
	if err != nil {
		return nil, err
	}
	p := &parser{toks: toks}
	n, err := p.parsePipe()
	if err != nil {
		return nil, err
	}
	if p.peek().kind != tEOF {
		return nil, p.fail("unexpected token")
	}
	return n, nil
}

type parser struct {
	toks []token
	i    int
}

func (p *parser) peek() token { return p.toks[p.i] }

func (p *parser) next() token {
	t := p.toks[p.i]
	if t.kind != tEOF {
		p.i++
	}
	return t
}

func (p *parser) fail(msg string) error { return &SyntaxError{p.peek().pos, msg} }

func (p *parser) isPunct(s string) bool {
	t := p.toks[p.i]
	return t.kind == tPunct && t.text == s
}

func (p *parser) isKeyword(s string) bool {
	t := p.toks[p.i]
	return t.kind == tIdent && t.text == s
}

func (p *parser) acceptPunct(s string) bool {
	if p.isPunct(s) {
		p.i++
		return true
	}
	return false
}

func (p *parser) expectPunct(s string) error {
	if !p.acceptPunct(s) {
		return p.fail("expected '" + s + "'")
	}
	return nil
}

func (p *parser) expectKeyword(s string) error {
	if !p.isKeyword(s) {
		return p.fail("expected '" + s + "'")
	}
	p.i++
	return nil
}

// pipe := comma [ "|" pipe ] | comma "as" "$" IDENT "|" pipe
// The source of a binding is always a postfix term, which parseComma returns
// unchanged when no operator follows it.
func (p *parser) parsePipe() (Node, error) {
	left, err := p.parseComma()
	if err != nil {
		return nil, err
	}
	if p.isKeyword("as") {
		p.i++
		t := p.next()
		if t.kind != tVar {
			return nil, &SyntaxError{t.pos, "expected variable after 'as'"}
		}
		if err := p.expectPunct("|"); err != nil {
			return nil, err
		}
		body, err := p.parsePipe()
		if err != nil {
			return nil, err
		}
		return &As{Source: left, Name: t.text, Body: body}, nil
	}
	if p.acceptPunct("|") {
		right, err := p.parsePipe()
		if err != nil {
			return nil, err
		}
		return &Pipe{left, right}, nil
	}
	return left, nil
}

func (p *parser) parseComma() (Node, error) {
	left, err := p.parseOr()
	if err != nil {
		return nil, err
	}
	for p.acceptPunct(",") {
		right, err := p.parseOr()
		if err != nil {
			return nil, err
		}
		left = &Comma{left, right}
	}
	return left, nil
}

func (p *parser) parseOr() (Node, error) {
	left, err := p.parseAnd()
	if err != nil {
		return nil, err
	}
	for p.isKeyword("or") {
		p.i++
		right, err := p.parseAnd()
		if err != nil {
			return nil, err
		}
		left = &Or{left, right}
	}
	return left, nil
}

func (p *parser) parseAnd() (Node, error) {
	left, err := p.parseCmp()
	if err != nil {
		return nil, err
	}
	for p.isKeyword("and") {
		p.i++
		right, err := p.parseCmp()
		if err != nil {
			return nil, err
		}
		left = &And{left, right}
	}
	return left, nil
}

var cmpOps = map[string]Op{"==": OpEq, "!=": OpNe, "<": OpLt, "<=": OpLe, ">": OpGt, ">=": OpGe}

func (p *parser) parseCmp() (Node, error) {
	left, err := p.parseAdd()
	if err != nil {
		return nil, err
	}
	if t := p.peek(); t.kind == tPunct {
		if op, ok := cmpOps[t.text]; ok {
			p.i++
			right, err := p.parseAdd()
			if err != nil {
				return nil, err
			}
			return &Binary{op, left, right}, nil
		}
	}
	return left, nil
}

func (p *parser) parseAdd() (Node, error) {
	left, err := p.parseMul()
	if err != nil {
		return nil, err
	}
	for {
		var op Op
		switch {
		case p.isPunct("+"):
			op = OpAdd
		case p.isPunct("-"):
			op = OpSub
		default:
			return left, nil
		}
		p.i++
		right, err := p.parseMul()
		if err != nil {
			return nil, err
		}
		left = &Binary{op, left, right}
	}
}

func (p *parser) parseMul() (Node, error) {
	left, err := p.parseUnary()
	if err != nil {
		return nil, err
	}
	for {
		var op Op
		switch {
		case p.isPunct("*"):
			op = OpMul
		case p.isPunct("/"):
			op = OpDiv
		case p.isPunct("%"):
			op = OpMod
		default:
			return left, nil
		}
		p.i++
		right, err := p.parseUnary()
		if err != nil {
			return nil, err
		}
		left = &Binary{op, left, right}
	}
}

func (p *parser) parseUnary() (Node, error) {
	if p.acceptPunct("-") {
		x, err := p.parseUnary()
		if err != nil {
			return nil, err
		}
		return negate(x), nil
	}
	return p.parsePostfix()
}

func negate(x Node) Node {
	if l, ok := x.(*Literal); ok && l.Val.Kind() == value.KindNumber {
		return &Literal{value.Number(-l.Val.Float())}
	}
	return &Neg{x}
}

func (p *parser) parsePostfix() (Node, error) {
	n, isPath, err := p.parsePrimary()
	if err != nil {
		return nil, err
	}
	for {
		switch {
		case p.isPunct("?"):
			p.i++
			if isPath {
				switch t := n.(type) {
				case *Index:
					t.Opt = true
				case *Slice:
					t.Opt = true
				case *Iterate:
					t.Opt = true
				}
				isPath = false
			} else {
				n = &Try{n}
			}
		case p.isPunct("."):
			t := p.toks[p.i+1]
			if t.kind == tIdent && !keywords[t.text] {
				p.i += 2
				n = &Index{Term: n, Key: &Literal{value.String(t.text)}}
			} else if t.kind == tStr {
				p.i += 2
				n = &Index{Term: n, Key: &Literal{value.String(t.text)}}
			} else {
				return n, nil
			}
			isPath = true
		case p.isPunct("["):
			p.i++
			var err error
			if n, err = p.parseBracket(n); err != nil {
				return nil, err
			}
			isPath = true
		default:
			return n, nil
		}
	}
}

// parseBracket parses what follows "[" in a suffix.
func (p *parser) parseBracket(term Node) (Node, error) {
	if p.acceptPunct("]") {
		return &Iterate{Term: term}, nil
	}
	var from Node
	if !p.isPunct(":") {
		var err error
		if from, err = p.parsePipe(); err != nil {
			return nil, err
		}
		if p.acceptPunct("]") {
			return &Index{Term: term, Key: from}, nil
		}
	}
	if err := p.expectPunct(":"); err != nil {
		return nil, err
	}
	var to Node
	if !p.isPunct("]") {
		var err error
		if to, err = p.parsePipe(); err != nil {
			return nil, err
		}
	}
	if err := p.expectPunct("]"); err != nil {
		return nil, err
	}
	return &Slice{Term: term, From: from, To: to}, nil
}

// parsePrimary returns the node and whether it is a path suffix (so that a
// directly following "?" makes only that operation optional).
func (p *parser) parsePrimary() (Node, bool, error) {
	start := p.i
	t := p.next()
	switch t.kind {
	case tNum:
		return &Literal{value.Number(t.num)}, false, nil
	case tStr:
		return &Literal{value.String(t.text)}, false, nil
	case tVar:
		return &Var{t.text}, false, nil
	case tPunct:
		switch t.text {
		case ".":
			nt := p.peek()
			if nt.kind == tStr {
				p.i++
				return &Index{Term: &Identity{}, Key: &Literal{value.String(nt.text)}}, true, nil
			}
			if nt.kind == tIdent && !keywords[nt.text] {
				p.i++
				return &Index{Term: &Identity{}, Key: &Literal{value.String(nt.text)}}, true, nil
			}
			return &Identity{}, false, nil
		case "(":
			n, err := p.parsePipe()
			if err != nil {
				return nil, false, err
			}
			if err := p.expectPunct(")"); err != nil {
				return nil, false, err
			}
			return n, false, nil
		case "[":
			if p.acceptPunct("]") {
				return &Array{}, false, nil
			}
			n, err := p.parsePipe()
			if err != nil {
				return nil, false, err
			}
			if err := p.expectPunct("]"); err != nil {
				return nil, false, err
			}
			return &Array{n}, false, nil
		case "{":
			n, err := p.parseObject()
			return n, false, err
		}
	case tIdent:
		switch t.text {
		case "true":
			return &Literal{value.True}, false, nil
		case "false":
			return &Literal{value.False}, false, nil
		case "null":
			return &Literal{value.Null}, false, nil
		case "if":
			n, err := p.parseIf()
			return n, false, err
		case "reduce":
			n, err := p.parseReduce()
			return n, false, err
		}
		if keywords[t.text] {
			break
		}
		call := &Call{Name: t.text}
		if p.acceptPunct("(") {
			for {
				a, err := p.parsePipe()
				if err != nil {
					return nil, false, err
				}
				call.Args = append(call.Args, a)
				if p.acceptPunct(";") {
					continue
				}
				if err := p.expectPunct(")"); err != nil {
					return nil, false, err
				}
				break
			}
		}
		return call, false, nil
	}
	p.i = start
	return nil, false, p.fail("unexpected token")
}

func (p *parser) parseIf() (Node, error) {
	cond, err := p.parsePipe()
	if err != nil {
		return nil, err
	}
	if err := p.expectKeyword("then"); err != nil {
		return nil, err
	}
	then, err := p.parsePipe()
	if err != nil {
		return nil, err
	}
	n := &If{Cond: cond, Then: then}
	switch {
	case p.isKeyword("elif"):
		p.i++
		rest, err := p.parseIf()
		if err != nil {
			return nil, err
		}
		n.Else = rest
		return n, nil
	case p.isKeyword("else"):
		p.i++
		if n.Else, err = p.parsePipe(); err != nil {
			return nil, err
		}
	}
	if err := p.expectKeyword("end"); err != nil {
		return nil, err
	}
	return n, nil
}

func (p *parser) parseReduce() (Node, error) {
	src, err := p.parsePostfix()
	if err != nil {
		return nil, err
	}
	if err := p.expectKeyword("as"); err != nil {
		return nil, err
	}
	v := p.next()
	if v.kind != tVar {
		return nil, &SyntaxError{v.pos, "expected variable"}
	}
	if err := p.expectPunct("("); err != nil {
		return nil, err
	}
	init, err := p.parsePipe()
	if err != nil {
		return nil, err
	}
	if err := p.expectPunct(";"); err != nil {
		return nil, err
	}
	upd, err := p.parsePipe()
	if err != nil {
		return nil, err
	}
	if err := p.expectPunct(")"); err != nil {
		return nil, err
	}
	return &Reduce{Source: src, Name: v.text, Init: init, Update: upd}, nil
}

func (p *parser) parseObject() (Node, error) {
	obj := &Object{}
	if !p.acceptPunct("}") {
		for {
			e, err := p.parseEntry()
			if err != nil {
				return nil, err
			}
			obj.Entries = append(obj.Entries, e)
			if p.acceptPunct(",") {
				continue
			}
			if err := p.expectPunct("}"); err != nil {
				return nil, err
			}
			break
		}
	}
	seen := map[string]bool{}
	obj.DistinctLiteralKeys = true
	for _, e := range obj.Entries {
		l, ok := e.Key.(*Literal)
		if !ok || l.Val.Kind() != value.KindString || seen[l.Val.Str()] {
			obj.DistinctLiteralKeys = false
			break
		}
		seen[l.Val.Str()] = true
	}
	return obj, nil
}

func (p *parser) parseEntry() (ObjEntry, error) {
	t := p.next()
	var key Node
	switch {
	case t.kind == tIdent && !keywords[t.text], t.kind == tStr:
		key = &Literal{value.String(t.text)}
		if !p.isPunct(":") {
			return ObjEntry{key, &Index{Term: &Identity{}, Key: key}}, nil
		}
	case t.kind == tVar:
		return ObjEntry{&Literal{value.String(t.text)}, &Var{t.text}}, nil
	case t.kind == tPunct && t.text == "(":
		k, err := p.parsePipe()
		if err != nil {
			return ObjEntry{}, err
		}
		if err := p.expectPunct(")"); err != nil {
			return ObjEntry{}, err
		}
		key = k
	default:
		return ObjEntry{}, &SyntaxError{t.pos, "invalid object key"}
	}
	if err := p.expectPunct(":"); err != nil {
		return ObjEntry{}, err
	}
	val, err := p.parseObjTerm()
	if err != nil {
		return ObjEntry{}, err
	}
	for p.acceptPunct("|") {
		r, err := p.parseObjTerm()
		if err != nil {
			return ObjEntry{}, err
		}
		val = &Pipe{val, r}
	}
	return ObjEntry{key, val}, nil
}

func (p *parser) parseObjTerm() (Node, error) {
	if p.acceptPunct("-") {
		x, err := p.parseObjTerm()
		if err != nil {
			return nil, err
		}
		return negate(x), nil
	}
	return p.parsePostfix()
}
