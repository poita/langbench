package jq

import (
	"fmt"

	"jq/value"
)

type parser struct {
	toks []token
	pos  int
	// lastPostfix is the node most recently returned by parsePostfix; it lets
	// parsePipe recognise "postfix as $x | ..." without backtracking.
	lastPostfix *node
}

func parseFilter(src string) (*node, error) {
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
		return nil, p.errorf("unexpected token %q", p.describe(p.peek()))
	}
	return n, nil
}

func (p *parser) peek() token { return p.toks[p.pos] }

func (p *parser) next() token {
	t := p.toks[p.pos]
	if t.kind != tEOF {
		p.pos++
	}
	return t
}

func (p *parser) describe(t token) string {
	if t.kind == tEOF {
		return "end of input"
	}
	return t.text
}

func (p *parser) errorf(format string, args ...any) error {
	return fmt.Errorf("jq: parse error at offset %d: %s", p.peek().pos, fmt.Sprintf(format, args...))
}

func (p *parser) isOp(s string) bool {
	t := p.peek()
	return t.kind == tOp && t.text == s
}

func (p *parser) isWord(s string) bool {
	t := p.peek()
	return t.kind == tIdent && t.text == s
}

func (p *parser) expectOp(s string) error {
	if !p.isOp(s) {
		return p.errorf("expected %q, found %q", s, p.describe(p.peek()))
	}
	p.pos++
	return nil
}

func (p *parser) expectWord(s string) error {
	if !p.isWord(s) {
		return p.errorf("expected %q, found %q", s, p.describe(p.peek()))
	}
	p.pos++
	return nil
}

// parsePipe := postfix "as" "$" IDENT "|" pipe | comma [ "|" pipe ]
func (p *parser) parsePipe() (*node, error) {
	lhs, err := p.parseComma()
	if err != nil {
		return nil, err
	}
	if p.isWord("as") && lhs == p.lastPostfix {
		p.pos++
		v := p.next()
		if v.kind != tVar {
			return nil, p.errorf("expected variable after 'as'")
		}
		if err := p.expectOp("|"); err != nil {
			return nil, err
		}
		body, err := p.parsePipe()
		if err != nil {
			return nil, err
		}
		return finish(&node{kind: nBind, a: lhs, b: body, name: v.text}), nil
	}
	if p.isOp("|") {
		p.pos++
		rhs, err := p.parsePipe()
		if err != nil {
			return nil, err
		}
		return finish(&node{kind: nPipe, a: lhs, b: rhs}), nil
	}
	return lhs, nil
}

func (p *parser) parseComma() (*node, error) {
	lhs, err := p.parseOr()
	if err != nil {
		return nil, err
	}
	for p.isOp(",") {
		p.pos++
		rhs, err := p.parseOr()
		if err != nil {
			return nil, err
		}
		lhs = finish(&node{kind: nComma, a: lhs, b: rhs})
	}
	return lhs, nil
}

func (p *parser) parseOr() (*node, error) {
	lhs, err := p.parseAnd()
	if err != nil {
		return nil, err
	}
	for p.isWord("or") {
		p.pos++
		rhs, err := p.parseAnd()
		if err != nil {
			return nil, err
		}
		lhs = finish(&node{kind: nOr, a: lhs, b: rhs})
	}
	return lhs, nil
}

func (p *parser) parseAnd() (*node, error) {
	lhs, err := p.parseCmp()
	if err != nil {
		return nil, err
	}
	for p.isWord("and") {
		p.pos++
		rhs, err := p.parseCmp()
		if err != nil {
			return nil, err
		}
		lhs = finish(&node{kind: nAnd, a: lhs, b: rhs})
	}
	return lhs, nil
}

var cmpOps = map[string]binOp{"==": opEq, "!=": opNe, "<": opLt, "<=": opLe, ">": opGt, ">=": opGe}

func (p *parser) parseCmp() (*node, error) {
	lhs, err := p.parseAdd()
	if err != nil {
		return nil, err
	}
	t := p.peek()
	if t.kind == tOp {
		if op, ok := cmpOps[t.text]; ok {
			p.pos++
			rhs, err := p.parseAdd()
			if err != nil {
				return nil, err
			}
			return finish(&node{kind: nBinary, op: op, a: lhs, b: rhs}), nil
		}
	}
	return lhs, nil
}

func (p *parser) parseAdd() (*node, error) {
	lhs, err := p.parseMul()
	if err != nil {
		return nil, err
	}
	for {
		var op binOp
		switch {
		case p.isOp("+"):
			op = opAdd
		case p.isOp("-"):
			op = opSub
		default:
			return lhs, nil
		}
		p.pos++
		rhs, err := p.parseMul()
		if err != nil {
			return nil, err
		}
		lhs = finish(&node{kind: nBinary, op: op, a: lhs, b: rhs})
	}
}

func (p *parser) parseMul() (*node, error) {
	lhs, err := p.parseUnary()
	if err != nil {
		return nil, err
	}
	for {
		var op binOp
		switch {
		case p.isOp("*"):
			op = opMul
		case p.isOp("/"):
			op = opDiv
		case p.isOp("%"):
			op = opMod
		default:
			return lhs, nil
		}
		p.pos++
		rhs, err := p.parseUnary()
		if err != nil {
			return nil, err
		}
		lhs = finish(&node{kind: nBinary, op: op, a: lhs, b: rhs})
	}
}

func (p *parser) parseUnary() (*node, error) {
	if p.isOp("-") {
		p.pos++
		return p.negate(p.parseUnary)
	}
	return p.parsePostfix()
}

func (p *parser) negate(operand func() (*node, error)) (*node, error) {
	x, err := operand()
	if err != nil {
		return nil, err
	}
	if x.kind == nLiteral && x.val.IsNumber() {
		return finish(&node{kind: nLiteral, val: value.Number(-x.val.Float())}), nil
	}
	return finish(&node{kind: nNeg, a: x}), nil
}

// parsePostfix := primary { suffix }
func (p *parser) parsePostfix() (*node, error) {
	n, isPath, err := p.parsePrimary()
	if err != nil {
		return nil, err
	}
	for {
		switch {
		case p.isOp("."):
			// ".foo", `."foo"` or ".[" after a term.
			nt := p.toks[p.pos+1]
			dot := p.peek()
			switch {
			case nt.kind == tIdent && nt.pos == dot.end:
				p.pos += 2
				n = finish(&node{kind: nField, a: n, name: nt.text})
			case nt.kind == tStr:
				p.pos += 2
				n = finish(&node{kind: nField, a: n, name: nt.text})
			case nt.kind == tOp && nt.text == "[":
				p.pos++
				continue
			default:
				p.lastPostfix = n
				return n, nil
			}
			isPath = true
		case p.isOp("["):
			p.pos++
			var err error
			n, err = p.parseBracket(n)
			if err != nil {
				return nil, err
			}
			isPath = true
		case p.isOp("?"):
			p.pos++
			if isPath {
				n.opt = true
				n.single = false
				isPath = false
			} else {
				n = finish(&node{kind: nTry, a: n})
			}
		default:
			p.lastPostfix = n
			return n, nil
		}
	}
}

// parseBracket parses what follows "[" in a suffix: "]", "e]", "a:b]" ...
func (p *parser) parseBracket(target *node) (*node, error) {
	if p.isOp("]") {
		p.pos++
		return finish(&node{kind: nIterate, a: target}), nil
	}
	var from *node
	if !p.isOp(":") {
		var err error
		from, err = p.parsePipe()
		if err != nil {
			return nil, err
		}
		if p.isOp("]") {
			p.pos++
			return finish(&node{kind: nIndex, a: target, b: from}), nil
		}
	}
	if err := p.expectOp(":"); err != nil {
		return nil, err
	}
	var to *node
	if !p.isOp("]") {
		var err error
		to, err = p.parsePipe()
		if err != nil {
			return nil, err
		}
	}
	if err := p.expectOp("]"); err != nil {
		return nil, err
	}
	return finish(&node{kind: nSlice, a: target, b: from, c: to}), nil
}

var nullLit = value.Null

// parsePrimary parses a primary term. The bool reports whether the result is
// a path step (".foo") to which a following "?" attaches directly.
func (p *parser) parsePrimary() (*node, bool, error) {
	t := p.next()
	switch t.kind {
	case tNum:
		return finish(&node{kind: nLiteral, val: value.Number(t.num)}), false, nil
	case tStr:
		return finish(&node{kind: nLiteral, val: value.String(t.text)}), false, nil
	case tVar:
		return finish(&node{kind: nVar, name: t.text}), false, nil
	case tOp:
		switch t.text {
		case ".":
			id := finish(&node{kind: nIdentity})
			nt := p.peek()
			if nt.kind == tIdent && nt.pos == t.end {
				p.pos++
				return finish(&node{kind: nField, a: id, name: nt.text}), true, nil
			}
			if nt.kind == tStr && nt.pos == t.end {
				p.pos++
				return finish(&node{kind: nField, a: id, name: nt.text}), true, nil
			}
			return id, false, nil
		case "(":
			n, err := p.parsePipe()
			if err != nil {
				return nil, false, err
			}
			if err := p.expectOp(")"); err != nil {
				return nil, false, err
			}
			return n, false, nil
		case "[":
			if p.isOp("]") {
				p.pos++
				return finish(&node{kind: nArray}), false, nil
			}
			n, err := p.parsePipe()
			if err != nil {
				return nil, false, err
			}
			if err := p.expectOp("]"); err != nil {
				return nil, false, err
			}
			return finish(&node{kind: nArray, a: n}), false, nil
		case "{":
			n, err := p.parseObject()
			return n, false, err
		}
	case tIdent:
		n, err := p.parseWord(t)
		return n, false, err
	}
	p.pos--
	return nil, false, p.errorf("unexpected %q", p.describe(t))
}

func (p *parser) parseWord(t token) (*node, error) {
	switch t.text {
	case "true":
		return finish(&node{kind: nLiteral, val: value.True}), nil
	case "false":
		return finish(&node{kind: nLiteral, val: value.False}), nil
	case "null":
		return finish(&node{kind: nLiteral, val: nullLit}), nil
	case "if":
		return p.parseIf()
	case "reduce":
		src, err := p.parsePostfix()
		if err != nil {
			return nil, err
		}
		if err := p.expectWord("as"); err != nil {
			return nil, err
		}
		v := p.next()
		if v.kind != tVar {
			return nil, p.errorf("expected variable after 'as'")
		}
		if err := p.expectOp("("); err != nil {
			return nil, err
		}
		init, err := p.parsePipe()
		if err != nil {
			return nil, err
		}
		if err := p.expectOp(";"); err != nil {
			return nil, err
		}
		upd, err := p.parsePipe()
		if err != nil {
			return nil, err
		}
		if err := p.expectOp(")"); err != nil {
			return nil, err
		}
		return finish(&node{kind: nReduce, a: src, b: init, c: upd, name: v.text}), nil
	}
	var args []*node
	if p.isOp("(") {
		p.pos++
		for {
			a, err := p.parsePipe()
			if err != nil {
				return nil, err
			}
			args = append(args, a)
			if p.isOp(";") {
				p.pos++
				continue
			}
			if err := p.expectOp(")"); err != nil {
				return nil, err
			}
			break
		}
	}
	id, ok := lookupBuiltin(t.text, len(args))
	if !ok {
		return nil, fmt.Errorf("jq: unknown function %s/%d", t.text, len(args))
	}
	return finish(&node{kind: nCall, fn: id, args: args}), nil
}

func (p *parser) parseIf() (*node, error) {
	cond, err := p.parsePipe()
	if err != nil {
		return nil, err
	}
	if err := p.expectWord("then"); err != nil {
		return nil, err
	}
	then, err := p.parsePipe()
	if err != nil {
		return nil, err
	}
	var els *node
	switch {
	case p.isWord("elif"):
		p.pos++
		els, err = p.parseIf()
		if err != nil {
			return nil, err
		}
		return finish(&node{kind: nIf, a: cond, b: then, c: els}), nil
	case p.isWord("else"):
		p.pos++
		els, err = p.parsePipe()
		if err != nil {
			return nil, err
		}
	default:
		els = finish(&node{kind: nIdentity})
	}
	if err := p.expectWord("end"); err != nil {
		return nil, err
	}
	return finish(&node{kind: nIf, a: cond, b: then, c: els}), nil
}

func (p *parser) parseObject() (*node, error) {
	n := &node{kind: nObject}
	if p.isOp("}") {
		p.pos++
		finish(n)
		return n, nil
	}
	for {
		var e objEntry
		t := p.next()
		explicit := true
		switch {
		case t.kind == tIdent:
			e.key = finish(&node{kind: nLiteral, val: value.String(t.text)})
			if !p.isOp(":") {
				e.val = finish(&node{kind: nField, a: finish(&node{kind: nIdentity}), name: t.text})
				explicit = false
			}
		case t.kind == tStr:
			e.key = finish(&node{kind: nLiteral, val: value.String(t.text)})
			if !p.isOp(":") {
				e.val = finish(&node{kind: nField, a: finish(&node{kind: nIdentity}), name: t.text})
				explicit = false
			}
		case t.kind == tVar:
			e.key = finish(&node{kind: nLiteral, val: value.String(t.text)})
			e.val = finish(&node{kind: nVar, name: t.text})
			explicit = false
		case t.kind == tOp && t.text == "(":
			k, err := p.parsePipe()
			if err != nil {
				return nil, err
			}
			if err := p.expectOp(")"); err != nil {
				return nil, err
			}
			e.key = k
		default:
			p.pos--
			return nil, p.errorf("bad object key %q", p.describe(t))
		}
		if explicit {
			if err := p.expectOp(":"); err != nil {
				return nil, err
			}
			v, err := p.parseObjVal()
			if err != nil {
				return nil, err
			}
			e.val = v
		}
		n.entries = append(n.entries, e)
		if p.isOp(",") {
			p.pos++
			continue
		}
		if err := p.expectOp("}"); err != nil {
			return nil, err
		}
		break
	}
	finish(n)
	return n, nil
}

// objval := objterm { "|" objterm }
func (p *parser) parseObjVal() (*node, error) {
	lhs, err := p.parseObjTerm()
	if err != nil {
		return nil, err
	}
	for p.isOp("|") {
		p.pos++
		rhs, err := p.parseObjTerm()
		if err != nil {
			return nil, err
		}
		lhs = finish(&node{kind: nPipe, a: lhs, b: rhs})
	}
	return lhs, nil
}

func (p *parser) parseObjTerm() (*node, error) {
	if p.isOp("-") {
		p.pos++
		return p.negate(p.parseObjTerm)
	}
	return p.parsePostfix()
}

// finish computes derived static properties of a freshly built node.
func finish(n *node) *node {
	switch n.kind {
	case nIdentity, nLiteral, nVar, nArray:
		n.single = true
	case nField, nIterate:
		n.single = n.kind == nField && !n.opt && n.a.single
	case nIndex:
		n.single = !n.opt && n.a.single && n.b.single
	case nSlice:
		n.single = !n.opt && n.a.single && (n.b == nil || n.b.single) && (n.c == nil || n.c.single)
	case nPipe, nBinary, nAnd, nOr:
		n.single = n.a.single && n.b.single
	case nNeg:
		n.single = n.a.single
	case nIf:
		n.single = n.a.single && n.b.single && n.c.single
	case nBind:
		n.single = n.a.single && n.b.single
	case nReduce:
		n.single = n.b.single
	case nCall:
		n.single = builtinSingle(n)
	case nObject:
		n.single = true
		seen := map[string]bool{}
		n.litKeys = true
		for _, e := range n.entries {
			if !e.key.single || !e.val.single {
				n.single = false
			}
			if e.key.kind != nLiteral || seen[e.key.val.Str()] {
				n.litKeys = false
			} else {
				seen[e.key.val.Str()] = true
			}
		}
	}
	return n
}
