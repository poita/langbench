package jq

import "fmt"

// Filter is a compiled jq filter. It is immutable and safe for concurrent use.
type Filter struct {
	src  string
	root node
}

// Compile parses a filter expression.
func Compile(src string) (*Filter, error) {
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
		return nil, p.errHere("unexpected token")
	}
	return &Filter{src: src, root: n}, nil
}

// MustCompile is like Compile but panics on error.
func MustCompile(src string) *Filter {
	f, err := Compile(src)
	if err != nil {
		panic(err)
	}
	return f
}

// String returns the filter's source text.
func (f *Filter) String() string { return f.src }

// Run evaluates the filter on input, calling yield for each result in order.
// Evaluation is lazy: it stops at the first error, either one raised by the
// filter (an *Error) or one returned by yield, which Run returns unchanged.
func (f *Filter) Run(input Value, yield func(Value) error) error {
	return f.root.eval(nil, input, yield)
}

// Collect runs the filter and gathers all results. On error it returns the
// results produced before the error together with the error.
func (f *Filter) Collect(input Value) ([]Value, error) {
	var res []Value
	err := f.Run(input, func(v Value) error {
		res = append(res, v)
		return nil
	})
	return res, err
}

type parser struct {
	toks []token
	pos  int
}

func (p *parser) peek() token { return p.toks[p.pos] }

func (p *parser) next() token {
	t := p.toks[p.pos]
	if t.kind != tEOF {
		p.pos++
	}
	return t
}

func (p *parser) errHere(msg string) error {
	return &FilterError{Pos: p.peek().pos, Msg: msg}
}

func (p *parser) isPunct(s string) bool {
	t := p.peek()
	return t.kind == tPunct && t.s == s
}

func (p *parser) isIdent(s string) bool {
	t := p.peek()
	return t.kind == tIdent && t.s == s
}

func (p *parser) acceptPunct(s string) bool {
	if p.isPunct(s) {
		p.pos++
		return true
	}
	return false
}

func (p *parser) expectPunct(s string) error {
	if !p.acceptPunct(s) {
		return p.errHere(fmt.Sprintf("expected %q", s))
	}
	return nil
}

func (p *parser) expectKeyword(s string) error {
	if !p.isIdent(s) {
		return p.errHere(fmt.Sprintf("expected %q", s))
	}
	p.pos++
	return nil
}

// pipe := comma [ "as" $v "|" pipe | "|" pipe ]
func (p *parser) parsePipe() (node, error) {
	lhs, err := p.parseComma()
	if err != nil {
		return nil, err
	}
	if p.isIdent("as") {
		p.pos++
		t := p.next()
		if t.kind != tVar {
			return nil, &FilterError{t.pos, "expected variable after 'as'"}
		}
		if err := p.expectPunct("|"); err != nil {
			return nil, err
		}
		body, err := p.parsePipe()
		if err != nil {
			return nil, err
		}
		return &bindNode{src: lhs, name: t.s, body: body}, nil
	}
	if p.acceptPunct("|") {
		rhs, err := p.parsePipe()
		if err != nil {
			return nil, err
		}
		return &pipeNode{lhs, rhs}, nil
	}
	return lhs, nil
}

func (p *parser) parseComma() (node, error) {
	lhs, err := p.parseOr()
	if err != nil {
		return nil, err
	}
	for p.acceptPunct(",") {
		rhs, err := p.parseOr()
		if err != nil {
			return nil, err
		}
		lhs = &commaNode{lhs, rhs}
	}
	return lhs, nil
}

func (p *parser) parseOr() (node, error) {
	lhs, err := p.parseAnd()
	if err != nil {
		return nil, err
	}
	for p.isIdent("or") {
		p.pos++
		rhs, err := p.parseAnd()
		if err != nil {
			return nil, err
		}
		lhs = &orNode{lhs, rhs}
	}
	return lhs, nil
}

func (p *parser) parseAnd() (node, error) {
	lhs, err := p.parseCmp()
	if err != nil {
		return nil, err
	}
	for p.isIdent("and") {
		p.pos++
		rhs, err := p.parseCmp()
		if err != nil {
			return nil, err
		}
		lhs = &andNode{lhs, rhs}
	}
	return lhs, nil
}

func (p *parser) parseCmp() (node, error) {
	lhs, err := p.parseAdd()
	if err != nil {
		return nil, err
	}
	if t := p.peek(); t.kind == tPunct {
		switch t.s {
		case "==", "!=", "<", "<=", ">", ">=":
			p.pos++
			rhs, err := p.parseAdd()
			if err != nil {
				return nil, err
			}
			return newBin(t.s, lhs, rhs), nil
		}
	}
	return lhs, nil
}

func newBin(op string, l, r node) node {
	return &binNode{op: op, l: l, r: r, fn: binaryOps[op]}
}

func (p *parser) parseAdd() (node, error) {
	lhs, err := p.parseMul()
	if err != nil {
		return nil, err
	}
	for p.isPunct("+") || p.isPunct("-") {
		op := p.next().s
		rhs, err := p.parseMul()
		if err != nil {
			return nil, err
		}
		lhs = newBin(op, lhs, rhs)
	}
	return lhs, nil
}

func (p *parser) parseMul() (node, error) {
	lhs, err := p.parseUnary()
	if err != nil {
		return nil, err
	}
	for p.isPunct("*") || p.isPunct("/") || p.isPunct("%") {
		op := p.next().s
		rhs, err := p.parseUnary()
		if err != nil {
			return nil, err
		}
		lhs = newBin(op, lhs, rhs)
	}
	return lhs, nil
}

func (p *parser) parseUnary() (node, error) {
	if p.acceptPunct("-") {
		x, err := p.parseUnary()
		if err != nil {
			return nil, err
		}
		return &negNode{x}, nil
	}
	return p.parsePostfix()
}

func (p *parser) parsePostfix() (node, error) {
	n, err := p.parsePrimary()
	if err != nil {
		return nil, err
	}
	// access is true while the last thing parsed is an index/iterate/slice
	// suffix, which a following "?" makes tolerant instead of wrapping in try.
	access := false
	if _, ok := n.(*indexNode); ok && p.toks[p.pos-1].kind != tPunct {
		access = true // primary ".foo" / ".\"foo\""
	}
	for {
		t := p.peek()
		if t.kind != tPunct {
			return n, nil
		}
		switch t.s {
		case ".":
			nt := p.toks[p.pos+1]
			if nt.kind != tIdent && nt.kind != tStr {
				return nil, &FilterError{nt.pos, "expected field name after '.'"}
			}
			p.pos += 2
			n = &indexNode{term: n, key: &literalNode{nt.s}}
			access = true
		case "[":
			p.pos++
			n, err = p.parseBracket(n)
			if err != nil {
				return nil, err
			}
			access = true
		case "?":
			p.pos++
			if access {
				n = markOptional(n)
			} else {
				n = &tryNode{n}
			}
			access = false
		default:
			return n, nil
		}
	}
}

// markOptional applies "?" to n: tolerant access directly after an
// index/iterate/slice suffix, otherwise try.
func markOptional(n node) node {
	switch x := n.(type) {
	case *indexNode:
		if !x.opt {
			x.opt = true
			return x
		}
	case *iterNode:
		if !x.opt {
			x.opt = true
			return x
		}
	case *sliceNode:
		if !x.opt {
			x.opt = true
			return x
		}
	}
	return &tryNode{n}
}

// parseBracket parses what follows "[" in a suffix position.
func (p *parser) parseBracket(term node) (node, error) {
	if p.acceptPunct("]") {
		return &iterNode{term: term}, nil
	}
	var from, to node
	var err error
	if !p.isPunct(":") {
		from, err = p.parsePipe()
		if err != nil {
			return nil, err
		}
	}
	if p.acceptPunct(":") {
		if !p.isPunct("]") {
			to, err = p.parsePipe()
			if err != nil {
				return nil, err
			}
		}
		if err := p.expectPunct("]"); err != nil {
			return nil, err
		}
		return &sliceNode{term: term, from: from, to: to}, nil
	}
	if err := p.expectPunct("]"); err != nil {
		return nil, err
	}
	return &indexNode{term: term, key: from}, nil
}

func (p *parser) parsePrimary() (node, error) {
	t := p.next()
	switch t.kind {
	case tNum:
		return &literalNode{t.num}, nil
	case tStr:
		return &literalNode{t.s}, nil
	case tVar:
		return &varNode{t.s}, nil
	case tPunct:
		switch t.s {
		case ".":
			nt := p.peek()
			if (nt.kind == tIdent || nt.kind == tStr) && !nt.space {
				p.pos++
				return &indexNode{term: identityNode{}, key: &literalNode{nt.s}}, nil
			}
			return identityNode{}, nil
		case "(":
			n, err := p.parsePipe()
			if err != nil {
				return nil, err
			}
			if err := p.expectPunct(")"); err != nil {
				return nil, err
			}
			return n, nil
		case "[":
			if p.acceptPunct("]") {
				return &arrayNode{}, nil
			}
			n, err := p.parsePipe()
			if err != nil {
				return nil, err
			}
			if err := p.expectPunct("]"); err != nil {
				return nil, err
			}
			return &arrayNode{n}, nil
		case "{":
			return p.parseObject()
		}
	case tIdent:
		switch t.s {
		case "true":
			return &literalNode{true}, nil
		case "false":
			return &literalNode{false}, nil
		case "null":
			return &literalNode{nil}, nil
		case "if":
			return p.parseIf()
		case "reduce":
			return p.parseReduce()
		}
		return p.parseCall(t)
	}
	return nil, &FilterError{t.pos, "unexpected token"}
}

func (p *parser) parseIf() (node, error) {
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
	n := &ifNode{cond: cond, then: then}
	switch {
	case p.isIdent("elif"):
		p.pos++
		n.els, err = p.parseIf() // elif is a nested if sharing the final "end"
		return n, err
	case p.isIdent("else"):
		p.pos++
		n.els, err = p.parsePipe()
		if err != nil {
			return nil, err
		}
	}
	if err := p.expectKeyword("end"); err != nil {
		return nil, err
	}
	return n, nil
}

func (p *parser) parseReduce() (node, error) {
	src, err := p.parsePostfix()
	if err != nil {
		return nil, err
	}
	if err := p.expectKeyword("as"); err != nil {
		return nil, err
	}
	v := p.next()
	if v.kind != tVar {
		return nil, &FilterError{v.pos, "expected variable"}
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
	return &reduceNode{src: src, name: v.s, init: init, update: upd}, nil
}

func (p *parser) parseObject() (node, error) {
	obj := &objectNode{}
	if p.acceptPunct("}") {
		return obj, nil
	}
	for {
		ent, err := p.parseEntry()
		if err != nil {
			return nil, err
		}
		obj.entries = append(obj.entries, ent)
		if p.acceptPunct(",") {
			continue
		}
		if err := p.expectPunct("}"); err != nil {
			return nil, err
		}
		return obj, nil
	}
}

func (p *parser) parseEntry() (objEntry, error) {
	t := p.next()
	var key node
	switch t.kind {
	case tIdent, tStr:
		key = &literalNode{t.s}
		if !p.isPunct(":") { // {a} / {"a"}
			return objEntry{key, &indexNode{term: identityNode{}, key: &literalNode{t.s}}}, nil
		}
	case tVar:
		return objEntry{&literalNode{t.s}, &varNode{t.s}}, nil
	case tPunct:
		if t.s != "(" {
			return objEntry{}, &FilterError{t.pos, "bad object key"}
		}
		k, err := p.parsePipe()
		if err != nil {
			return objEntry{}, err
		}
		if err := p.expectPunct(")"); err != nil {
			return objEntry{}, err
		}
		key = k
	default:
		return objEntry{}, &FilterError{t.pos, "bad object key"}
	}
	if err := p.expectPunct(":"); err != nil {
		return objEntry{}, err
	}
	val, err := p.parseObjVal()
	return objEntry{key, val}, err
}

// objval := objterm { "|" objterm }
func (p *parser) parseObjVal() (node, error) {
	lhs, err := p.parseObjTerm()
	if err != nil {
		return nil, err
	}
	if p.acceptPunct("|") {
		rhs, err := p.parseObjVal()
		if err != nil {
			return nil, err
		}
		return &pipeNode{lhs, rhs}, nil
	}
	return lhs, nil
}

func (p *parser) parseObjTerm() (node, error) {
	if p.acceptPunct("-") {
		x, err := p.parseObjTerm()
		if err != nil {
			return nil, err
		}
		return &negNode{x}, nil
	}
	return p.parsePostfix()
}

// parseCall parses a builtin call whose name token has been consumed.
func (p *parser) parseCall(name token) (node, error) {
	var args []node
	if p.acceptPunct("(") {
		for {
			a, err := p.parsePipe()
			if err != nil {
				return nil, err
			}
			args = append(args, a)
			if p.acceptPunct(";") {
				continue
			}
			if err := p.expectPunct(")"); err != nil {
				return nil, err
			}
			break
		}
	}
	n, err := newBuiltin(name.s, args)
	if err != nil {
		return nil, &FilterError{name.pos, err.Error()}
	}
	return n, nil
}
