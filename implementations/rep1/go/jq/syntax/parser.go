package syntax

// Parse parses a filter. It returns an *Error for malformed input.
func Parse(src string) (n Node, err error) {
	defer func() {
		if r := recover(); r != nil {
			if e, ok := r.(*Error); ok {
				n, err = nil, e
				return
			}
			panic(r)
		}
	}()
	p := &parser{toks: lex(src)}
	n = p.parsePipe()
	if t := p.peek(); t.kind != tEOF {
		fail(t.pos, "unexpected %s", describe(t))
	}
	return n, nil
}

type parser struct {
	toks []token
	pos  int
}

func describe(t token) string {
	switch t.kind {
	case tEOF:
		return "end of input"
	case tStr:
		return "string"
	case tNum:
		return "number " + t.text
	case tVar:
		return "$" + t.text
	case tField:
		return "." + t.text
	}
	return "'" + t.text + "'"
}

func (p *parser) peek() token { return p.toks[p.pos] }

func (p *parser) peekAt(n int) token {
	if p.pos+n < len(p.toks) {
		return p.toks[p.pos+n]
	}
	return p.toks[len(p.toks)-1]
}

func (p *parser) next() token {
	t := p.toks[p.pos]
	if t.kind != tEOF {
		p.pos++
	}
	return t
}

func (p *parser) isOp(s string) bool {
	t := p.peek()
	return t.kind == tOp && t.text == s
}

func (p *parser) isWord(s string) bool {
	t := p.peek()
	return t.kind == tIdent && t.text == s
}

func (p *parser) acceptOp(s string) bool {
	if p.isOp(s) {
		p.pos++
		return true
	}
	return false
}

func (p *parser) expectOp(s string) {
	if !p.acceptOp(s) {
		t := p.peek()
		fail(t.pos, "expected '%s' but found %s", s, describe(t))
	}
}

func (p *parser) expectWord(s string) {
	if !p.isWord(s) {
		t := p.peek()
		fail(t.pos, "expected '%s' but found %s", s, describe(t))
	}
	p.pos++
}

func (p *parser) parsePipe() Node {
	lhs := p.parseComma()
	if p.acceptOp("|") {
		return &Pipe{lhs, p.parsePipe()}
	}
	return lhs
}

func (p *parser) parseComma() Node {
	lhs := p.parseOr()
	for p.acceptOp(",") {
		lhs = &Comma{lhs, p.parseOr()}
	}
	return lhs
}

func (p *parser) parseOr() Node {
	lhs := p.parseAnd()
	for p.isWord("or") {
		p.pos++
		lhs = &Or{lhs, p.parseAnd()}
	}
	return lhs
}

func (p *parser) parseAnd() Node {
	lhs := p.parseCmp()
	for p.isWord("and") {
		p.pos++
		lhs = &And{lhs, p.parseCmp()}
	}
	return lhs
}

func (p *parser) parseCmp() Node {
	lhs := p.parseAdd()
	if t := p.peek(); t.kind == tOp {
		switch t.text {
		case "==", "!=", "<", "<=", ">", ">=":
			p.pos++
			return &Binary{t.text, lhs, p.parseAdd()}
		}
	}
	return lhs
}

func (p *parser) parseAdd() Node {
	lhs := p.parseMul()
	for {
		t := p.peek()
		if t.kind == tOp && (t.text == "+" || t.text == "-") {
			p.pos++
			lhs = &Binary{t.text, lhs, p.parseMul()}
			continue
		}
		return lhs
	}
}

func (p *parser) parseMul() Node {
	lhs := p.parseUnary()
	for {
		t := p.peek()
		if t.kind == tOp && (t.text == "*" || t.text == "/" || t.text == "%") {
			p.pos++
			lhs = &Binary{t.text, lhs, p.parseUnary()}
			continue
		}
		return lhs
	}
}

func (p *parser) parseUnary() Node {
	if p.acceptOp("-") {
		return &Neg{p.parseUnary()}
	}
	return p.parsePostfix()
}

// parsePostfix parses a postfix term, and, when it is followed by "as", the
// variable binding whose body extends as far right as possible.
func (p *parser) parsePostfix() Node {
	n := p.parseTerm()
	if p.isWord("as") {
		p.pos++
		name := p.expectVar()
		p.expectOp("|")
		return &As{Src: n, Name: name, Body: p.parsePipe()}
	}
	return n
}

func (p *parser) expectVar() string {
	t := p.peek()
	if t.kind != tVar {
		fail(t.pos, "expected variable but found %s", describe(t))
	}
	p.pos++
	return t.text
}

// parseTerm parses a primary followed by any number of suffixes.
func (p *parser) parseTerm() Node {
	n, canOpt := p.parsePrimary()
	for {
		t := p.peek()
		switch {
		case t.kind == tField:
			p.pos++
			n, canOpt = &Index{Term: n, Key: &Literal{t.text}}, true
		case t.kind == tOp && t.text == ".":
			nt := p.peekAt(1)
			if nt.kind == tStr {
				p.pos += 2
				n, canOpt = &Index{Term: n, Key: &Literal{nt.text}}, true
			} else if nt.kind == tOp && nt.text == "[" {
				p.pos++ // ".[" continues the path
			} else {
				return n
			}
		case t.kind == tOp && t.text == "[":
			p.pos++
			n = p.parseBracket(n)
			canOpt = true
		case t.kind == tOp && t.text == "?":
			p.pos++
			if canOpt {
				switch x := n.(type) {
				case *Index:
					x.Opt = true
				case *Iterate:
					x.Opt = true
				case *Slice:
					x.Opt = true
				}
			} else {
				n = &Try{n}
			}
			canOpt = false
		default:
			return n
		}
	}
}

// parseBracket parses the rest of a suffix after '['.
func (p *parser) parseBracket(term Node) Node {
	if p.acceptOp("]") {
		return &Iterate{Term: term}
	}
	var from Node
	if !p.isOp(":") {
		from = p.parsePipe()
		if p.acceptOp("]") {
			return &Index{Term: term, Key: from}
		}
	}
	p.expectOp(":")
	var to Node
	if !p.isOp("]") {
		to = p.parsePipe()
	}
	p.expectOp("]")
	return &Slice{Term: term, From: from, To: to}
}

func (p *parser) parsePrimary() (Node, bool) {
	t := p.next()
	switch t.kind {
	case tNum:
		return &Literal{t.num}, false
	case tStr:
		return &Literal{t.text}, false
	case tVar:
		return &Var{Name: t.text, Pos: t.pos}, false
	case tField:
		return &Index{Term: &Identity{}, Key: &Literal{t.text}}, true
	case tOp:
		switch t.text {
		case ".":
			if nt := p.peek(); nt.kind == tStr {
				p.pos++
				return &Index{Term: &Identity{}, Key: &Literal{nt.text}}, true
			}
			return &Identity{}, false
		case "(":
			n := p.parsePipe()
			p.expectOp(")")
			return n, false
		case "[":
			if p.acceptOp("]") {
				return &Array{}, false
			}
			n := p.parsePipe()
			p.expectOp("]")
			return &Array{n}, false
		case "{":
			return p.parseObject(), false
		}
	case tIdent:
		switch t.text {
		case "true":
			return &Literal{true}, false
		case "false":
			return &Literal{false}, false
		case "null":
			return &Literal{nil}, false
		case "if":
			return p.parseIf(), false
		case "reduce":
			return p.parseReduce(), false
		case "then", "elif", "else", "end", "as", "and", "or":
			fail(t.pos, "unexpected keyword '%s'", t.text)
		}
		call := &Call{Name: t.text, Pos: t.pos}
		if p.acceptOp("(") {
			call.Args = append(call.Args, p.parsePipe())
			for p.acceptOp(";") {
				call.Args = append(call.Args, p.parsePipe())
			}
			p.expectOp(")")
		}
		return call, false
	}
	fail(t.pos, "unexpected %s", describe(t))
	return nil, false
}

func (p *parser) parseIf() Node {
	cond := p.parsePipe()
	p.expectWord("then")
	then := p.parsePipe()
	n := &If{Cond: cond, Then: then}
	switch {
	case p.isWord("elif"):
		p.pos++
		n.Else = p.parseIf() // consumes through the shared "end"
		return n
	case p.isWord("else"):
		p.pos++
		n.Else = p.parsePipe()
	}
	p.expectWord("end")
	return n
}

func (p *parser) parseReduce() Node {
	src := p.parseTerm()
	p.expectWord("as")
	name := p.expectVar()
	p.expectOp("(")
	init := p.parsePipe()
	p.expectOp(";")
	update := p.parsePipe()
	p.expectOp(")")
	return &Reduce{Src: src, Name: name, Init: init, Update: update}
}

func (p *parser) parseObject() Node {
	obj := &Object{}
	if p.acceptOp("}") {
		return obj
	}
	for {
		obj.Entries = append(obj.Entries, p.parseEntry())
		if p.acceptOp("}") {
			return obj
		}
		p.expectOp(",")
	}
}

func (p *parser) parseEntry() Entry {
	t := p.next()
	var key Node
	switch {
	case t.kind == tIdent || t.kind == tStr:
		key = &Literal{t.text}
		if !p.isOp(":") {
			if t.kind == tIdent && (t.text == "true" || t.text == "false" || t.text == "null") {
				fail(t.pos, "object key shorthand needs a name")
			}
			return Entry{key, &Index{Term: &Identity{}, Key: &Literal{t.text}}}
		}
	case t.kind == tVar:
		return Entry{&Literal{t.text}, &Var{Name: t.text, Pos: t.pos}}
	case t.kind == tOp && t.text == "(":
		key = p.parsePipe()
		p.expectOp(")")
		if !p.isOp(":") {
			fail(p.peek().pos, "expected ':' after computed key")
		}
	default:
		fail(t.pos, "unexpected %s in object", describe(t))
	}
	p.expectOp(":")
	return Entry{key, p.parseObjVal()}
}

func (p *parser) parseObjVal() Node {
	n := p.parseObjTerm()
	for p.acceptOp("|") {
		n = &Pipe{n, p.parseObjTerm()}
	}
	return n
}

func (p *parser) parseObjTerm() Node {
	if p.acceptOp("-") {
		return &Neg{p.parseObjTerm()}
	}
	return p.parseTerm()
}
